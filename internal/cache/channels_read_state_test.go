package cache

import (
	"testing"
)

func newRSChannel(t *testing.T, db *DB, id, workspaceID string) {
	t.Helper()
	if err := db.UpsertWorkspace(Workspace{ID: workspaceID, Name: "ws"}); err != nil {
		t.Fatalf("UpsertWorkspace: %v", err)
	}
	if err := db.UpsertChannel(Channel{ID: id, WorkspaceID: workspaceID, Name: id, Type: "channel"}); err != nil {
		t.Fatalf("UpsertChannel: %v", err)
	}
}

func TestUpdateChannelReadState_WritesBothColumns(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer db.Close()
	newRSChannel(t, db, "C1", "T1")

	if err := db.UpdateChannelReadState("C1", "1700000000.000001", true); err != nil {
		t.Fatalf("UpdateChannelReadState: %v", err)
	}
	state, err := db.GetChannelReadState("C1")
	if err != nil {
		t.Fatalf("GetChannelReadState: %v", err)
	}
	if state.LastReadTS != "1700000000.000001" {
		t.Errorf("LastReadTS = %q, want %q", state.LastReadTS, "1700000000.000001")
	}
	if !state.HasUnread {
		t.Errorf("HasUnread = false, want true")
	}
}

func TestUpdateChannelReadState_EmptyTSPreservesExisting(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer db.Close()
	newRSChannel(t, db, "C1", "T1")

	if err := db.UpdateChannelReadState("C1", "1700000000.000001", false); err != nil {
		t.Fatalf("first update: %v", err)
	}
	if err := db.UpdateChannelReadState("C1", "", true); err != nil {
		t.Fatalf("second update: %v", err)
	}
	state, err := db.GetChannelReadState("C1")
	if err != nil {
		t.Fatalf("GetChannelReadState: %v", err)
	}
	if state.LastReadTS != "1700000000.000001" {
		t.Errorf("LastReadTS = %q, want preserved %q", state.LastReadTS, "1700000000.000001")
	}
	if !state.HasUnread {
		t.Errorf("HasUnread = false, want true")
	}
}

func TestUpdateChannelReadState_Idempotent(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer db.Close()
	newRSChannel(t, db, "C1", "T1")

	for i := 0; i < 3; i++ {
		if err := db.UpdateChannelReadState("C1", "1700000000.000001", true); err != nil {
			t.Fatalf("iter %d: %v", i, err)
		}
	}
	state, _ := db.GetChannelReadState("C1")
	if state.LastReadTS != "1700000000.000001" || !state.HasUnread {
		t.Errorf("state = %+v after 3 writes", state)
	}
}

func TestBatchUpdateChannelReadState_WritesAll(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer db.Close()
	newRSChannel(t, db, "C1", "T1")
	newRSChannel(t, db, "C2", "T1")
	newRSChannel(t, db, "C3", "T1")

	updates := []ChannelReadStateUpdate{
		{ChannelID: "C1", LastReadTS: "1.0001", HasUnread: true},
		{ChannelID: "C2", LastReadTS: "1.0002", HasUnread: false},
		{ChannelID: "C3", LastReadTS: "", HasUnread: true},
	}
	if err := db.BatchUpdateChannelReadState(updates); err != nil {
		t.Fatalf("BatchUpdateChannelReadState: %v", err)
	}
	s1, _ := db.GetChannelReadState("C1")
	if s1.LastReadTS != "1.0001" || !s1.HasUnread {
		t.Errorf("C1 = %+v", s1)
	}
	s2, _ := db.GetChannelReadState("C2")
	if s2.LastReadTS != "1.0002" || s2.HasUnread {
		t.Errorf("C2 = %+v", s2)
	}
	s3, _ := db.GetChannelReadState("C3")
	if s3.LastReadTS != "" || !s3.HasUnread {
		t.Errorf("C3 = %+v (LastReadTS should be preserved empty)", s3)
	}
}

func TestBatchUpdateChannelReadState_Transactional(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer db.Close()
	newRSChannel(t, db, "C1", "T1")

	// Seed C1
	if err := db.UpdateChannelReadState("C1", "1.0", false); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Empty batch is a no-op and returns nil.
	if err := db.BatchUpdateChannelReadState(nil); err != nil {
		t.Errorf("nil batch: %v", err)
	}
	if err := db.BatchUpdateChannelReadState([]ChannelReadStateUpdate{}); err != nil {
		t.Errorf("empty batch: %v", err)
	}
	// Original state untouched
	s, _ := db.GetChannelReadState("C1")
	if s.LastReadTS != "1.0" || s.HasUnread {
		t.Errorf("after empty batch C1 = %+v", s)
	}
}

func TestGetWorkspaceReadState_ReturnsAllChannels(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer db.Close()
	newRSChannel(t, db, "C1", "T1")
	newRSChannel(t, db, "C2", "T1")
	newRSChannel(t, db, "C3", "T1")
	newRSChannel(t, db, "C4", "T2") // different workspace

	_ = db.UpdateChannelReadState("C1", "1.0001", true)
	_ = db.UpdateChannelReadState("C2", "1.0002", false)
	// C3 untouched — defaults

	got, err := db.GetWorkspaceReadState("T1")
	if err != nil {
		t.Fatalf("GetWorkspaceReadState: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d entries, want 3 (C3 must be included with defaults): %+v", len(got), got)
	}
	if got["C1"].LastReadTS != "1.0001" || !got["C1"].HasUnread {
		t.Errorf("C1 = %+v", got["C1"])
	}
	if got["C2"].LastReadTS != "1.0002" || got["C2"].HasUnread {
		t.Errorf("C2 = %+v", got["C2"])
	}
	if got["C3"].LastReadTS != "" || got["C3"].HasUnread {
		t.Errorf("C3 default = %+v", got["C3"])
	}
	if _, ok := got["C4"]; ok {
		t.Errorf("C4 from other workspace should not be returned")
	}
}

func TestWorkspacesWithUnreads(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer db.Close()
	newRSChannel(t, db, "C1", "T1")
	newRSChannel(t, db, "C2", "T2")
	newRSChannel(t, db, "C3", "T3")

	_ = db.UpdateChannelReadState("C1", "1.0", true)
	_ = db.UpdateChannelReadState("C3", "1.0", true)
	// C2/T2 has no unreads

	got, err := db.WorkspacesWithUnreads()
	if err != nil {
		t.Fatalf("WorkspacesWithUnreads: %v", err)
	}
	want := map[string]bool{"T1": true, "T3": true}
	if len(got) != 2 {
		t.Fatalf("got %d ids, want 2: %v", len(got), got)
	}
	for _, id := range got {
		if !want[id] {
			t.Errorf("unexpected workspace %q", id)
		}
	}
}

func TestUpsertChannel_DoesNotClobberReadState(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer db.Close()
	newRSChannel(t, db, "C1", "T1")

	// Set read state.
	if err := db.UpdateChannelReadState("C1", "1700000000.000001", true); err != nil {
		t.Fatalf("UpdateChannelReadState: %v", err)
	}

	// Re-upsert the channel with zero-value LastReadTS/UnreadCount.
	// This mirrors what bootstrap (upsertChannelInDB) does today.
	if err := db.UpsertChannel(Channel{
		ID:          "C1",
		WorkspaceID: "T1",
		Name:        "renamed",
		Type:        "channel",
	}); err != nil {
		t.Fatalf("re-upsert: %v", err)
	}

	state, err := db.GetChannelReadState("C1")
	if err != nil {
		t.Fatalf("GetChannelReadState: %v", err)
	}
	if state.LastReadTS != "1700000000.000001" {
		t.Errorf("LastReadTS = %q, want preserved %q (clobber regression!)", state.LastReadTS, "1700000000.000001")
	}
	if !state.HasUnread {
		t.Errorf("HasUnread = false after upsert (clobber regression!)")
	}
}
