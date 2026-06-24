package image

import (
	"bytes"
	"image"
	imgcolor "image/color"
	"strings"
	"testing"
)

func TestKitty_UploadEscapeFormat(t *testing.T) {
	t.Setenv("TMUX", "")
	src := makeSolid(64, 64, imgcolor.RGBA{1, 2, 3, 255})
	r := NewKittyRenderer(NewRegistry())
	out := r.Render(src, image.Pt(10, 5))

	if out.OnFlush == nil {
		t.Fatal("expected OnFlush set on first render")
	}
	if out.ID == 0 {
		t.Fatal("expected non-zero ID")
	}

	var buf bytes.Buffer
	if err := out.OnFlush(&buf); err != nil {
		t.Fatal(err)
	}
	s := buf.String()
	if !strings.HasPrefix(s, "\x1b_G") {
		t.Errorf("expected \\e_G prefix, got %q", s[:minInt(20, len(s))])
	}
	if !strings.HasSuffix(s, "\x1b\\") {
		t.Errorf("expected \\e\\ suffix")
	}
	if !strings.Contains(s, "a=T") {
		t.Error("missing a=T (transmit-and-display, required for unicode-placeholder virtual placement)")
	}
	if !strings.Contains(s, "c=10") || !strings.Contains(s, "r=5") {
		t.Error("missing c=<cols>,r=<rows> for virtual placement footprint")
	}
	if !strings.Contains(s, "f=100") {
		t.Error("missing f=100 (PNG)")
	}
	if !strings.Contains(s, "U=1") {
		t.Error("missing U=1 (unicode placeholder)")
	}
}

func TestKitty_WrapForTmux(t *testing.T) {
	inner := "\x1b_Ga=T;payload\x1b\\"
	want := "\x1bPtmux;\x1b\x1b_Ga=T;payload\x1b\x1b\\\x1b\\"
	if got := wrapForTmux(inner); got != want {
		t.Fatalf("wrapForTmux() = %q, want %q", got, want)
	}
}

func TestKitty_UploadEscapeWrappedInTmux(t *testing.T) {
	t.Setenv("TMUX", "/tmp/tmux")

	var buf bytes.Buffer
	if err := emitKittyUpload(&buf, 42, "abcd", 10, 5); err != nil {
		t.Fatal(err)
	}
	s := buf.String()
	if !strings.HasPrefix(s, "\x1bPtmux;\x1b\x1b_G") {
		t.Fatalf("expected tmux-wrapped kitty upload, got %q", s[:minInt(20, len(s))])
	}
	if !strings.HasSuffix(s, "\x1b\x1b\\\x1b\\") {
		t.Fatalf("expected doubled inner ST plus tmux ST suffix, got %q", s)
	}
	if !strings.Contains(s, "a=T") || !strings.Contains(s, "U=1") {
		t.Fatalf("wrapped upload missing kitty parameters: %q", s)
	}
}

func TestKitty_SecondRenderSameImageNoFlush(t *testing.T) {
	t.Setenv("TMUX", "")
	reg := NewRegistry()
	r := NewKittyRenderer(reg)
	src := makeSolid(8, 8, imgcolor.RGBA{1, 2, 3, 255})

	r.SetSource("test-key", src)
	out1 := r.RenderKey("test-key", image.Pt(4, 2))
	if out1.OnFlush == nil {
		t.Fatal("first render should flush")
	}
	// Confirm the upload was actually delivered: only AFTER the
	// closure has run does the renderer know the terminal received
	// the bytes. Without this, the second RenderKey should still
	// hand back an OnFlush — see TestKitty_RerenderBeforeUploadStillFlushes.
	if err := out1.OnFlush(&bytes.Buffer{}); err != nil {
		t.Fatalf("first OnFlush failed: %v", err)
	}

	out2 := r.RenderKey("test-key", image.Pt(4, 2))
	if out2.OnFlush != nil {
		t.Error("second render of same (key, size) after a successful upload should not flush again")
	}
	if out2.ID != out1.ID {
		t.Error("ID should be stable across renders of same (key, size)")
	}
}

// TestKitty_RerenderBeforeUploadStillFlushes captures the messages-pane
// cache-rebuild race that previously dropped images on the floor:
//
//  1. buildCache calls RenderKey → fresh=true, OnFlush closure captured
//     in a viewEntry. View() hasn't run yet, so the closure has NOT
//     fired (no bytes on the wire).
//  2. SetMessages is called again (e.g. network-verify after a cache hit)
//     → m.cache = nil, discarding the viewEntry and its closure.
//  3. buildCache runs again → RenderKey for the same (key, target).
//
// Under the buggy semantic, step 3 would return OnFlush=nil because the
// registry had already minted an ID — even though no bytes were ever
// sent to the terminal. The placement cells reference an image_id the
// terminal has never seen, so the image renders as blank cells.
//
// The correct semantic: RenderKey returns a fireable OnFlush until a
// previous closure has confirmed delivery. The test holds OnFlush from
// the first render WITHOUT firing it, then asserts the second render
// also hands back a fireable OnFlush.
func TestKitty_RerenderBeforeUploadStillFlushes(t *testing.T) {
	t.Setenv("TMUX", "")
	reg := NewRegistry()
	r := NewKittyRenderer(reg)
	src := makeSolid(8, 8, imgcolor.RGBA{1, 2, 3, 255})

	r.SetSource("test-key", src)
	out1 := r.RenderKey("test-key", image.Pt(4, 2))
	if out1.OnFlush == nil {
		t.Fatal("first render should flush (precondition)")
	}
	// Intentionally do NOT call out1.OnFlush — simulate the cache
	// rebuild that throws the closure away before it can fire.

	out2 := r.RenderKey("test-key", image.Pt(4, 2))
	if out2.OnFlush == nil {
		t.Fatal("second render before any successful upload must still flush — otherwise the image_id is referenced by placement cells the terminal never received")
	}
	if out2.ID != out1.ID {
		t.Errorf("ID should remain stable; got %d vs %d", out2.ID, out1.ID)
	}

	// After firing once, a third render should not flush again — one
	// successful upload per (key, target) is enough.
	if err := out2.OnFlush(&bytes.Buffer{}); err != nil {
		t.Fatalf("second OnFlush failed: %v", err)
	}
	out3 := r.RenderKey("test-key", image.Pt(4, 2))
	if out3.OnFlush != nil {
		t.Error("third render after a confirmed upload should not flush again")
	}
}

func TestKitty_PlaceholderRows(t *testing.T) {
	src := makeSolid(20, 20, imgcolor.RGBA{255, 255, 255, 255})
	r := NewKittyRenderer(NewRegistry())
	out := r.Render(src, image.Pt(10, 5))

	if len(out.Lines) != 5 {
		t.Fatalf("expected 5 lines, got %d", len(out.Lines))
	}
	for i, line := range out.Lines {
		if !strings.Contains(line, "\U0010EEEE") {
			t.Errorf("line %d missing placeholder rune: %q", i, line[:minInt(30, len(line))])
		}
		if !strings.Contains(line, "\x1b[38;2;") {
			t.Errorf("line %d missing 24-bit SGR: %q", i, line[:minInt(30, len(line))])
		}
	}
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// BenchmarkKitty_RenderKeyWarm measures the steady-state cost of
// RenderKey for an already-uploaded (key, target) -- the path that
// dominates buildCache in image-heavy channels. Pre-fix this was
// ~16ms/op on typical kitty terminals because buildPlaceholderLines
// re-ran cells.Y * cells.X strings.Builder writes per call. Post-fix
// (placeholder-line memoization) it should be a single map lookup.
//
// We pre-flush so the registry marks the image uploaded; subsequent
// RenderKey calls hit the "fresh=false" branch -- which still ran
// buildPlaceholderLines before the fix.
func BenchmarkKitty_RenderKeyWarm(b *testing.B) {
	t := image.Pt(60, 20)
	src := makeSolid(60*8, 20*16, imgcolor.RGBA{1, 2, 3, 255})
	r := NewKittyRenderer(NewRegistry())
	r.SetSource("bench", src)

	// First call returns OnFlush; emit it so the registry marks the
	// image uploaded. Subsequent calls hit the warm path.
	first := r.RenderKey("bench", t)
	if first.OnFlush != nil {
		_ = first.OnFlush(&bytes.Buffer{})
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.RenderKey("bench", t)
	}
}

// BenchmarkKitty_RenderKeyFreshRepeat exercises the path that
// dominates real-world channel-switch latency: an image whose
// OnFlush has not yet fired (off-screen viewEntries) so
// Registry.Lookup keeps returning fresh=true. Pre-fix every call
// re-ran bilinear-resize + PNG-encode + base64. Post-fix the
// payload cache should make these calls effectively free.
func BenchmarkKitty_RenderKeyFreshRepeat(b *testing.B) {
	t := image.Pt(60, 16)
	// 8x16 pixels per cell -> 480x256 source roughly matches a
	// typical Slack attachment thumbnail target.
	src := makeSolid(60*8, 16*16, imgcolor.RGBA{1, 2, 3, 255})
	r := NewKittyRenderer(NewRegistry())
	r.SetSource("bench-fresh", src)
	// Do NOT call OnFlush; this simulates an off-screen viewEntry
	// whose flush was never invoked. Subsequent RenderKey calls
	// will see fresh=true on every iteration.
	_ = r.RenderKey("bench-fresh", t)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.RenderKey("bench-fresh", t)
	}
}

// TestKitty_RenderKeyWarmMatchesCold guards the placeholder-line
// memoization: the cached output must be byte-identical to the
// freshly-computed output for the same (id, target).
func TestKitty_RenderKeyWarmMatchesCold(t *testing.T) {
	target := image.Pt(8, 4)
	src := makeSolid(64, 64, imgcolor.RGBA{1, 2, 3, 255})
	r := NewKittyRenderer(NewRegistry())
	r.SetSource("k", src)

	cold := r.RenderKey("k", target)
	if cold.OnFlush != nil {
		_ = cold.OnFlush(&bytes.Buffer{}) // mark uploaded
	}
	warm := r.RenderKey("k", target)

	if len(cold.Lines) != len(warm.Lines) {
		t.Fatalf("line count differs: cold=%d warm=%d", len(cold.Lines), len(warm.Lines))
	}
	for i := range cold.Lines {
		if cold.Lines[i] != warm.Lines[i] {
			t.Errorf("line %d differs:\n cold=%q\n warm=%q", i, cold.Lines[i], warm.Lines[i])
		}
	}
	if cold.ID != warm.ID {
		t.Errorf("ID differs: cold=%d warm=%d", cold.ID, warm.ID)
	}
}

// TestKitty_PayloadCacheUploadIdentity guards the payload memoization:
// when fresh=true is returned for the same (id, target) multiple times
// (the off-screen viewEntry case), each OnFlush invocation must emit
// byte-identical APC upload bytes. The first call's OnFlush runs the
// expensive resize+encode; subsequent calls reuse the cached payload.
// Without this guarantee, repeated cache rebuilds for the same image
// could produce divergent uploads and leave the terminal pointing at
// stale image data.
//
// We deliberately do NOT call MarkUploaded between the two RenderKey
// calls (i.e. we DO NOT invoke first.OnFlush). This is the exact path
// the bug fixes: an off-screen image whose OnFlush was never consumed
// by the visible-entry loop, then re-rendered on the next buildCache.
func TestKitty_PayloadCacheUploadIdentity(t *testing.T) {
	t.Setenv("TMUX", "")
	target := image.Pt(10, 6)
	src := makeSolid(80, 96, imgcolor.RGBA{200, 100, 50, 255})
	r := NewKittyRenderer(NewRegistry())
	r.SetSource("payload-test", src)

	first := r.RenderKey("payload-test", target)
	if first.OnFlush == nil {
		t.Fatal("first call: expected OnFlush set when fresh=true")
	}
	var firstBuf bytes.Buffer
	if err := first.OnFlush(&firstBuf); err != nil {
		t.Fatal(err)
	}

	// Note: we do NOT call MarkUploaded explicitly. The first OnFlush
	// did call it via the registry, so Lookup will now return
	// fresh=false. To force fresh=true again (the off-screen case),
	// use a different (key, target) bound to a different id but
	// reuse the source image -- this exercises the payload cache
	// path because the second call still goes through the
	// resize+encode branch with a fresh id.
	//
	// Simpler and more direct: hand-craft the off-screen scenario by
	// reaching past MarkUploaded via a fresh renderer where we never
	// drain OnFlush. Each fresh=true call must reuse the cached
	// payload for the SAME (id, target).
	r2 := NewKittyRenderer(NewRegistry())
	r2.SetSource("payload-test", src)
	a := r2.RenderKey("payload-test", target)
	b := r2.RenderKey("payload-test", target)
	if a.OnFlush == nil || b.OnFlush == nil {
		t.Fatal("both off-screen calls: expected OnFlush set when fresh=true")
	}
	var aBuf, bBuf bytes.Buffer
	if err := a.OnFlush(&aBuf); err != nil {
		t.Fatal(err)
	}
	if err := b.OnFlush(&bBuf); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(aBuf.Bytes(), bBuf.Bytes()) {
		t.Errorf("upload bytes differ between consecutive fresh=true calls\nlen a=%d b=%d", aBuf.Len(), bBuf.Len())
	}
}
