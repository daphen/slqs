package membership

import (
	"context"
	"sync"
	"testing"
	"time"

	"slqs/internal/cache"
)

// fakeMemberAPI implements ConversationMemberAPI for tests.
type fakeMemberAPI struct {
	mu     sync.Mutex
	calls  int
	result []string
	err    error
}

func (f *fakeMemberAPI) GetUsersInConversation(ctx context.Context, channelID string) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	return f.result, f.err
}

func (f *fakeMemberAPI) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

// captureSink records ChannelMembershipMsg pushes.
type captureSink struct {
	mu     sync.Mutex
	pushes []capturedPush
}
type capturedPush struct {
	channelID string
	memberIDs []string
}

func (s *captureSink) Push(channelID string, memberIDs []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := make([]string, len(memberIDs))
	copy(cp, memberIDs)
	s.pushes = append(s.pushes, capturedPush{channelID, cp})
}
func (s *captureSink) snapshot() []capturedPush {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]capturedPush, len(s.pushes))
	copy(out, s.pushes)
	return out
}

func newManagerForTest(t *testing.T) (*Manager, *fakeMemberAPI, *captureSink, *cache.DB) {
	t.Helper()
	db, err := cache.New(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	_ = db.UpsertWorkspace(cache.Workspace{ID: "T1", Name: "Test"})
	api := &fakeMemberAPI{}
	sink := &captureSink{}
	mgr := New("T1", api, db, sink.Push, nil /* userResolver */)
	return mgr, api, sink, db
}

func TestEnsureFreshCacheHitNoFetch(t *testing.T) {
	mgr, api, sink, db := newManagerForTest(t)
	defer db.Close()
	// Seed cache with recent meta.
	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1", "U2"}, time.Now().Unix())

	mgr.EnsureFresh(context.Background(), "C1")
	// EnsureFresh kicks off background work; wait for any push.
	waitForPush(t, sink, 1)

	if api.callCount() != 0 {
		t.Errorf("fresh cache should NOT trigger fetch; got %d calls", api.callCount())
	}
	pushes := sink.snapshot()
	if len(pushes) != 1 || pushes[0].channelID != "C1" {
		t.Errorf("expected 1 push for C1; got %+v", pushes)
	}
}

func TestEnsureFreshCacheMissTriggersFetch(t *testing.T) {
	mgr, api, sink, db := newManagerForTest(t)
	defer db.Close()
	api.result = []string{"U1", "U2", "U3"}

	mgr.EnsureFresh(context.Background(), "C1")
	waitForPush(t, sink, 1)     // initial empty push
	waitForCallCount(t, api, 1) // fetch happens
	waitForPush(t, sink, 2)     // post-fetch push

	if api.callCount() != 1 {
		t.Errorf("expected 1 fetch call; got %d", api.callCount())
	}
	pushes := sink.snapshot()
	if len(pushes) < 2 {
		t.Fatalf("expected >=2 pushes; got %d", len(pushes))
	}
	last := pushes[len(pushes)-1]
	if len(last.memberIDs) != 3 {
		t.Errorf("final push had %d members; want 3", len(last.memberIDs))
	}

	// Cache persisted?
	got, _ := db.ListChannelMembers("T1", "C1")
	if len(got) != 3 {
		t.Errorf("expected 3 cached members; got %d", len(got))
	}
}

func TestEnsureFreshStaleTriggersFetch(t *testing.T) {
	mgr, api, sink, db := newManagerForTest(t)
	defer db.Close()
	// Seed cache as stale (yesterday).
	stale := time.Now().Add(-25 * time.Hour).Unix()
	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1"}, stale)
	api.result = []string{"U1", "U2"}

	mgr.EnsureFresh(context.Background(), "C1")
	waitForPush(t, sink, 1)
	waitForCallCount(t, api, 1)
	waitForPush(t, sink, 2)

	if api.callCount() != 1 {
		t.Errorf("stale cache should trigger fetch; got %d calls", api.callCount())
	}
}

// Helpers — poll briefly because the Manager fans work to goroutines.
func waitForPush(t *testing.T, s *captureSink, n int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if len(s.snapshot()) >= n {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %d pushes; got %d", n, len(s.snapshot()))
}
func waitForCallCount(t *testing.T, api *fakeMemberAPI, n int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if api.callCount() >= n {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %d API calls", n)
}

func TestApplyJoinPersistsAndPushes(t *testing.T) {
	mgr, _, sink, db := newManagerForTest(t)
	defer db.Close()
	// Pre-seed C1 with U1 so the active set isn't empty.
	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1"}, time.Now().Unix())
	mgr.EnsureFresh(context.Background(), "C1")
	waitForPush(t, sink, 1)

	mgr.ApplyJoin("C1", "U_NEW")

	// Persisted?
	got, _ := db.ListChannelMembers("T1", "C1")
	found := false
	for _, id := range got {
		if id == "U_NEW" {
			found = true
		}
	}
	if !found {
		t.Errorf("U_NEW not persisted; cache = %v", got)
	}
	// Pushed?
	waitForPush(t, sink, 2)
	pushes := sink.snapshot()
	last := pushes[len(pushes)-1]
	hasNew := false
	for _, id := range last.memberIDs {
		if id == "U_NEW" {
			hasNew = true
		}
	}
	if !hasNew {
		t.Errorf("U_NEW missing from push: %v", last.memberIDs)
	}
}

func TestApplyLeaveDeletesAndPushes(t *testing.T) {
	mgr, _, sink, db := newManagerForTest(t)
	defer db.Close()
	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1", "U2"}, time.Now().Unix())
	mgr.EnsureFresh(context.Background(), "C1")
	waitForPush(t, sink, 1)

	mgr.ApplyLeave("C1", "U1")

	got, _ := db.ListChannelMembers("T1", "C1")
	for _, id := range got {
		if id == "U1" {
			t.Errorf("U1 still in cache after leave: %v", got)
		}
	}
}

func TestApplyJoinDoesNotBumpLastFullFetchAt(t *testing.T) {
	mgr, _, _, db := newManagerForTest(t)
	defer db.Close()
	originalTS := int64(12345)
	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1"}, originalTS)

	mgr.ApplyJoin("C1", "U_NEW")

	ts, _, _ := db.GetChannelMembershipMeta("T1", "C1")
	if ts != originalTS {
		t.Errorf("last_full_fetch_at = %d, want %d (deltas must not touch it)", ts, originalTS)
	}
}

func TestForceStaleDoesNotWipePersistedMembers(t *testing.T) {
	mgr, _, _, db := newManagerForTest(t)
	defer db.Close()

	// Seed cache without ever calling loadIntoMemory (cold in-memory).
	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1", "U2", "U3"}, time.Now().Unix())

	mgr.ForceStale("C1")

	got, _ := db.ListChannelMembers("T1", "C1")
	if len(got) != 3 {
		t.Errorf("members wiped: %v (cold-cache regression)", got)
	}
	ts, _, _ := db.GetChannelMembershipMeta("T1", "C1")
	if ts != 0 {
		t.Errorf("meta = %d, want 0", ts)
	}
}

func TestForceStaleCausesRefetch(t *testing.T) {
	mgr, api, sink, db := newManagerForTest(t)
	defer db.Close()
	// Seed as fresh.
	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1"}, time.Now().Unix())
	api.result = []string{"U1", "U2"}

	mgr.ForceStale("C1")
	mgr.EnsureFresh(context.Background(), "C1")

	waitForCallCount(t, api, 1)
	waitForPush(t, sink, 2)
}

// fakeResolver records calls for the resolver-invocation test.
type fakeResolver struct {
	mu   sync.Mutex
	seen []string
}

func (r *fakeResolver) Request(userID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seen = append(r.seen, userID)
}
func (r *fakeResolver) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, len(r.seen))
	copy(out, r.seen)
	return out
}

func TestBackgroundFetchTriggersResolverForEachID(t *testing.T) {
	db, _ := cache.New(":memory:")
	defer db.Close()
	_ = db.UpsertWorkspace(cache.Workspace{ID: "T1", Name: "Test"})

	api := &fakeMemberAPI{result: []string{"U1", "U2", "U3"}}
	sink := &captureSink{}
	resolver := &fakeResolver{}
	mgr := New("T1", api, db, sink.Push, resolver)

	mgr.EnsureFresh(context.Background(), "C1")
	waitForCallCount(t, api, 1)
	waitForPush(t, sink, 2)

	// Brief settle for the resolver Request calls.
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if len(resolver.snapshot()) >= 3 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	seen := resolver.snapshot()
	if len(seen) != 3 {
		t.Fatalf("expected resolver to see 3 IDs; got %v", seen)
	}
	// Verify each ID is present (order not required).
	want := map[string]bool{"U1": true, "U2": true, "U3": true}
	for _, id := range seen {
		if !want[id] {
			t.Errorf("unexpected ID %s", id)
		}
		delete(want, id)
	}
	if len(want) != 0 {
		t.Errorf("missing IDs: %v", want)
	}
}

func TestEnsureFreshConcurrentDoesNotDuplicate(t *testing.T) {
	mgr, api, _, db := newManagerForTest(t)
	defer db.Close()
	api.result = []string{"U1"}

	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			mgr.EnsureFresh(context.Background(), "C1")
		}()
	}
	wg.Wait()
	// Allow background goroutines to settle.
	time.Sleep(100 * time.Millisecond)

	if c := api.callCount(); c > 1 {
		t.Errorf("expected at most 1 fetch under concurrent EnsureFresh; got %d", c)
	}
}
