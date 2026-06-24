package emoji

import (
	"context"
	"errors"
	goimage "image"
	"io"
	"sync"
	"testing"
	"time"

	imgpkg "slqs/internal/image"
)

// fakeFetcher implements PlaceFetcher for unit tests. Behavior is
// controlled by the prerender map (warm hits) and a fetchFn closure
// (cold-path fetch behavior).
type fakeFetcher struct {
	mu         sync.Mutex
	prerender  map[string]imgpkg.Render // keyed by "<key>|<cx>x<cy>"
	fetchFn    func(ctx context.Context, req imgpkg.FetchRequest) (imgpkg.FetchResult, error)
	fetchCalls []imgpkg.FetchRequest
}

func newFakeFetcher() *fakeFetcher {
	return &fakeFetcher{prerender: map[string]imgpkg.Render{}}
}

func (f *fakeFetcher) prerenderKey(key string, t goimage.Point) string {
	return key + "|" + itoa(t.X) + "x" + itoa(t.Y)
}

func itoa(n int) string {
	// avoid strconv import here for brevity in tests
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

func (f *fakeFetcher) setPrerendered(key string, target goimage.Point, r imgpkg.Render) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.prerender[f.prerenderKey(key, target)] = r
}

func (f *fakeFetcher) Prerendered(key string, t goimage.Point, proto imgpkg.Protocol) (imgpkg.Render, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r, ok := f.prerender[f.prerenderKey(key, t)]
	return r, ok
}

func (f *fakeFetcher) Fetch(ctx context.Context, req imgpkg.FetchRequest) (imgpkg.FetchResult, error) {
	f.mu.Lock()
	f.fetchCalls = append(f.fetchCalls, req)
	fn := f.fetchFn
	f.mu.Unlock()
	if fn != nil {
		return fn(ctx, req)
	}
	return imgpkg.FetchResult{}, errors.New("fakeFetcher: no fetchFn set")
}

// fetchCallsSnapshot returns a copy of the recorded fetch requests under the
// mutex. Fetch runs on the background goroutine spawned by spawnEmojiFetch,
// so tests must read through this accessor (not ff.fetchCalls directly) to
// avoid racing that goroutine's append at Fetch above.
func (f *fakeFetcher) fetchCallsSnapshot() []imgpkg.FetchRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]imgpkg.FetchRequest, len(f.fetchCalls))
	copy(out, f.fetchCalls)
	return out
}

func TestPlace_InvalidInputs(t *testing.T) {
	ff := newFakeFetcher()
	ctx := PlaceContext{Fetcher: ff}

	cases := []struct {
		name string
		url  string
		cell int
		fctx PlaceContext
	}{
		{"empty url", "", 2, ctx},
		{"zero cells", "https://x", 0, ctx},
		{"negative cells", "https://x", -1, ctx},
		{"nil fetcher", "https://x", 2, PlaceContext{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s, flush, ok := Place(c.fctx, c.url, c.cell)
			if ok {
				t.Errorf("Place(%q, %d) = (%q, flush=%v, true), want ok=false", c.url, c.cell, s, flush != nil)
			}
			if s != "" {
				t.Errorf("Place(%q, %d) placement = %q, want \"\"", c.url, c.cell, s)
			}
		})
	}

	// The fetcher should not have been called for any of these inputs.
	if len(ff.fetchCalls) != 0 {
		t.Errorf("fetcher was called %d times for invalid inputs, want 0", len(ff.fetchCalls))
	}
}

func TestPlace_WarmPath_ReturnsKittyLine(t *testing.T) {
	ff := newFakeFetcher()
	url := "https://a.slack-edge.com/...1f44d.png"
	key := EmojiCacheKey(url)
	target := goimage.Pt(2, 1)

	// Seed a prerender hit: 2-cell-wide kitty placement string.
	wantLine := "\U0010EEEE\U0010EEEE" // two kitty placeholder runes (the real renderer emits this with diacritics + SGR fg; for the unit test, any deterministic placement string is fine)
	flushCalled := 0
	ff.setPrerendered(key, target, imgpkg.Render{
		Cells:    target,
		Lines:    []string{wantLine},
		Fallback: []string{wantLine},
		OnFlush: func(_ io.Writer) error {
			flushCalled++
			return nil
		},
	})

	ctx := PlaceContext{Fetcher: ff}
	got, flush, ok := Place(ctx, url, 2)
	if !ok {
		t.Fatalf("Place: ok=false, want true (warm path)")
	}
	if got != wantLine {
		t.Errorf("Place placement = %q, want %q", got, wantLine)
	}
	if flush == nil {
		t.Fatalf("Place: flush is nil, want a callback for the warm path")
	}
	// flush is io.Writer-shaped; call with a discarding writer to
	// verify it doesn't panic and increments the counter.
	if err := flush(discardWriter{}); err != nil {
		t.Errorf("flush returned err = %v, want nil", err)
	}
	if flushCalled != 1 {
		t.Errorf("flush invocation count = %d, want 1", flushCalled)
	}

	// No fetch goroutine should have been spawned on the warm path.
	if len(ff.fetchCalls) != 0 {
		t.Errorf("fetcher.Fetch called %d times on warm path, want 0", len(ff.fetchCalls))
	}
}

type discardWriter struct{}

func (discardWriter) Write(p []byte) (int, error) { return len(p), nil }

func TestPlace_ColdPath_SpawnsFetch(t *testing.T) {
	ff := newFakeFetcher()
	url := "https://a.slack-edge.com/...1f44d.png"

	// Configure fetch to succeed instantly. Prerender map is empty so
	// Prerendered returns false — cold path triggered.
	ff.fetchFn = func(ctx context.Context, req imgpkg.FetchRequest) (imgpkg.FetchResult, error) {
		return imgpkg.FetchResult{}, nil
	}

	done := make(chan EmojiImageReadyMsg, 1)
	pctx := PlaceContext{
		Fetcher: ff,
		SendMsg: func(m any) {
			if r, ok := m.(EmojiImageReadyMsg); ok {
				done <- r
			}
		},
	}

	got, flush, ok := Place(pctx, url, 2)
	if !ok {
		t.Fatalf("Place: ok=false, want true (cold path)")
	}
	if got != "  " {
		t.Errorf("cold-path placement = %q, want %q (two spaces)", got, "  ")
	}
	if flush != nil {
		t.Errorf("cold-path flush should be nil; got %T", flush)
	}

	// Wait for SendMsg to fire from the fetch goroutine.
	select {
	case msg := <-done:
		if msg.URL != url {
			t.Errorf("EmojiImageReadyMsg.URL = %q, want %q", msg.URL, url)
		}
	case <-time.After(time.Second):
		t.Fatal("SendMsg(EmojiImageReadyMsg) never fired within 1s")
	}

	// Exactly one fetch should have been issued.
	calls := ff.fetchCallsSnapshot()
	if len(calls) != 1 {
		t.Errorf("fetcher.Fetch called %d times, want 1", len(calls))
	}
	if got := calls[0]; got.URL != url || got.Key != EmojiCacheKey(url) || got.CellTarget != goimage.Pt(2, 1) {
		t.Errorf("FetchRequest = {Key:%q URL:%q CellTarget:%v}, want consistent with url and 2x1",
			got.Key, got.URL, got.CellTarget)
	}
}

func TestPlace_ColdPath_DedupsConcurrentCalls(t *testing.T) {
	ff := newFakeFetcher()
	url := "https://a.slack-edge.com/...1f44d.png"

	gate := make(chan struct{})
	ff.fetchFn = func(ctx context.Context, req imgpkg.FetchRequest) (imgpkg.FetchResult, error) {
		<-gate // hold the fetch until the test releases it
		return imgpkg.FetchResult{}, nil
	}

	// The deduped fetch goroutine signals completion via SendMsg exactly
	// once. We wait on it before inspecting fetchCalls so the read
	// happens-after the goroutine's append (otherwise the assertion races
	// the background Fetch).
	done := make(chan struct{}, 1)
	pctx := PlaceContext{
		Fetcher: ff,
		SendMsg: func(m any) {
			if _, ok := m.(EmojiImageReadyMsg); ok {
				select {
				case done <- struct{}{}:
				default:
				}
			}
		},
	}

	// Fire 20 concurrent Place calls for the same URL.
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			Place(pctx, url, 2)
		}()
	}

	// Give goroutines a moment to enqueue their fetches.
	time.Sleep(50 * time.Millisecond)
	close(gate)
	wg.Wait()

	// Wait for the single in-flight fetch goroutine to finish (and append
	// to fetchCalls) before asserting.
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("deduped fetch never completed within 1s")
	}

	// All Place calls should have observed the in-flight dedup and
	// only one Fetch should have actually been issued.
	if got := len(ff.fetchCallsSnapshot()); got != 1 {
		t.Errorf("concurrent Place calls produced %d Fetch invocations, want 1 (dedup failed)", got)
	}
}

func TestPlace_ColdPath_FetchError_LeavesNoInflight(t *testing.T) {
	resetNegativeEmojiCache()
	t.Cleanup(resetNegativeEmojiCache)

	ff := newFakeFetcher()
	url := "https://a.slack-edge.com/...1f44d.png"
	key := EmojiCacheKey(url)

	// First fetch fails. The inflight registration must clear so the
	// negative-cache short-circuit on the next Place call observes a
	// clean inflight map (the failure path must not leak inflight
	// entries even though retries are now blocked by the negative
	// cache).
	first := make(chan struct{})
	var once sync.Once
	ff.fetchFn = func(ctx context.Context, req imgpkg.FetchRequest) (imgpkg.FetchResult, error) {
		once.Do(func() { close(first) })
		return imgpkg.FetchResult{}, errors.New("network down")
	}

	pctx := PlaceContext{Fetcher: ff, SendMsg: func(any) {}}

	Place(pctx, url, 2)
	<-first

	// Give the deferred inflight cleanup time to run.
	deadline := time.Now().Add(time.Second)
	for {
		inflightEmojiMu.Lock()
		_, busy := inflightEmoji[key]
		inflightEmojiMu.Unlock()
		if !busy {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("inflight entry for %q never cleared after fetch error", key)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestPlace_NegativeCache_ShortCircuitsAfterFetchFailure verifies that
// once a URL has been marked failed (via spawnEmojiFetch's error path),
// subsequent Place() calls return ok=false so the caller can fall back
// to legacy glyph/text rendering instead of leaving a blank cold-cache
// reservation.
func TestPlace_NegativeCache_ShortCircuitsAfterFetchFailure(t *testing.T) {
	resetNegativeEmojiCache()
	t.Cleanup(resetNegativeEmojiCache)

	ff := newFakeFetcher()
	badURL := "https://a.slack-edge.com/...nonexistent.png"

	// Fetch always errors (404-style).
	fetchDone := make(chan struct{}, 1)
	ff.fetchFn = func(ctx context.Context, req imgpkg.FetchRequest) (imgpkg.FetchResult, error) {
		defer func() { fetchDone <- struct{}{} }()
		return imgpkg.FetchResult{}, errors.New("HTTP 404")
	}

	pctx := PlaceContext{Fetcher: ff, SendMsg: func(any) {}}

	// First Place: cold path, returns reservation + spawns fetch.
	s1, _, ok1 := Place(pctx, badURL, 2)
	if !ok1 {
		t.Fatalf("first Place should return ok=true (cold-path reservation)")
	}
	if s1 != "  " {
		t.Errorf("first Place placement = %q, want two spaces", s1)
	}

	// Wait for the fetch goroutine to complete and mark the URL failed.
	<-fetchDone
	// Allow the deferred inflight-cleanup + negative-cache mark to settle.
	deadline := time.Now().Add(time.Second)
	for !isEmojiURLFailed(badURL) {
		if time.Now().After(deadline) {
			t.Fatalf("negative cache never marked %q as failed", badURL)
		}
		time.Sleep(5 * time.Millisecond)
	}

	// Second Place: negative-cache short-circuit, returns ok=false.
	s2, _, ok2 := Place(pctx, badURL, 2)
	if ok2 {
		t.Errorf("second Place after fetch failure should return ok=false, got placement=%q ok=true", s2)
	}
	if s2 != "" {
		t.Errorf("second Place placement = %q, want \"\"", s2)
	}
}

// TestPlace_NegativeCache_DoesNotAffectOtherURLs verifies that marking
// one URL failed doesn't poison Place() for unrelated URLs.
func TestPlace_NegativeCache_DoesNotAffectOtherURLs(t *testing.T) {
	resetNegativeEmojiCache()
	t.Cleanup(resetNegativeEmojiCache)

	markEmojiURLFailed("https://x/bad.png")

	goodURL := "https://x/good.png"
	ff := newFakeFetcher()
	ff.fetchFn = func(ctx context.Context, req imgpkg.FetchRequest) (imgpkg.FetchResult, error) {
		return imgpkg.FetchResult{}, nil
	}
	pctx := PlaceContext{Fetcher: ff, SendMsg: func(any) {}}

	// good URL should still take the cold path.
	_, _, ok := Place(pctx, goodURL, 2)
	if !ok {
		t.Errorf("Place for unrelated URL after marking different URL failed: ok=false, want true")
	}
}

// TestPlace_NegativeCache_DispatchesReadyMsgOnFailure verifies that
// fetch failures still trigger an EmojiImageReadyMsg dispatch so the
// UI re-renders and the negative-cache decision takes effect.
func TestPlace_NegativeCache_DispatchesReadyMsgOnFailure(t *testing.T) {
	resetNegativeEmojiCache()
	t.Cleanup(resetNegativeEmojiCache)

	ff := newFakeFetcher()
	badURL := "https://x/bad.png"
	ff.fetchFn = func(ctx context.Context, req imgpkg.FetchRequest) (imgpkg.FetchResult, error) {
		return imgpkg.FetchResult{}, errors.New("HTTP 404")
	}

	gotMsg := make(chan EmojiImageReadyMsg, 1)
	pctx := PlaceContext{
		Fetcher: ff,
		SendMsg: func(m any) {
			if r, ok := m.(EmojiImageReadyMsg); ok {
				gotMsg <- r
			}
		},
	}

	Place(pctx, badURL, 2)

	select {
	case msg := <-gotMsg:
		if msg.URL != badURL {
			t.Errorf("EmojiImageReadyMsg.URL = %q, want %q", msg.URL, badURL)
		}
	case <-time.After(time.Second):
		t.Fatal("no EmojiImageReadyMsg dispatched after fetch failure")
	}
}
