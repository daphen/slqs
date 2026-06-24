package cache

import (
	"sort"
	"testing"
)

func TestUpsertAndListChannelMember(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	if err := db.UpsertChannelMember("T1", "C1", "U1", 100); err != nil {
		t.Fatal(err)
	}
	if err := db.UpsertChannelMember("T1", "C1", "U2", 100); err != nil {
		t.Fatal(err)
	}
	got, err := db.ListChannelMembers("T1", "C1")
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(got)
	if len(got) != 2 || got[0] != "U1" || got[1] != "U2" {
		t.Errorf("ListChannelMembers = %v, want [U1 U2]", got)
	}
}

func TestUpsertChannelMemberIdempotent(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	if err := db.UpsertChannelMember("T1", "C1", "U1", 100); err != nil {
		t.Fatal(err)
	}
	if err := db.UpsertChannelMember("T1", "C1", "U1", 200); err != nil {
		t.Fatalf("re-upsert errored: %v", err)
	}
	got, err := db.ListChannelMembers("T1", "C1")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Errorf("expected single row after re-upsert, got %v", got)
	}
}

func TestDeleteChannelMember(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	_ = db.UpsertChannelMember("T1", "C1", "U1", 100)
	_ = db.UpsertChannelMember("T1", "C1", "U2", 100)
	if err := db.DeleteChannelMember("T1", "C1", "U1"); err != nil {
		t.Fatal(err)
	}
	got, _ := db.ListChannelMembers("T1", "C1")
	if len(got) != 1 || got[0] != "U2" {
		t.Errorf("after delete, got %v, want [U2]", got)
	}
}

func TestDeleteMissingChannelMemberIsNoop(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	if err := db.DeleteChannelMember("T1", "C1", "U_GONE"); err != nil {
		t.Errorf("deleting nonexistent row should be noop, got %v", err)
	}
}

func TestReplaceChannelMembersUpdatesMeta(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	if err := db.ReplaceChannelMembers("T1", "C1", []string{"U1", "U2", "U3"}, 12345); err != nil {
		t.Fatal(err)
	}
	got, _ := db.ListChannelMembers("T1", "C1")
	sort.Strings(got)
	if len(got) != 3 {
		t.Errorf("ListChannelMembers = %v, want 3", got)
	}
	ts, ok, err := db.GetChannelMembershipMeta("T1", "C1")
	if err != nil {
		t.Fatal(err)
	}
	if !ok || ts != 12345 {
		t.Errorf("meta = (%d, %v), want (12345, true)", ts, ok)
	}
}

func TestReplaceChannelMembersReplacesNotAppends(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1", "U2"}, 100)
	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U2", "U3"}, 200)

	got, _ := db.ListChannelMembers("T1", "C1")
	sort.Strings(got)
	if len(got) != 2 || got[0] != "U2" || got[1] != "U3" {
		t.Errorf("ListChannelMembers after replace = %v, want [U2 U3]", got)
	}
	ts, _, _ := db.GetChannelMembershipMeta("T1", "C1")
	if ts != 200 {
		t.Errorf("meta last_full_fetch_at = %d, want 200", ts)
	}
}

func TestGetChannelMembershipMetaMissing(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	_, ok, err := db.GetChannelMembershipMeta("T1", "C_UNKNOWN")
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Error("expected ok=false for missing meta")
	}
}

func TestZeroChannelMembershipMetaPreservesMembers(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	_ = db.ReplaceChannelMembers("T1", "C1", []string{"U1", "U2"}, 12345)
	if err := db.ZeroChannelMembershipMeta("T1", "C1"); err != nil {
		t.Fatal(err)
	}

	// Members preserved.
	got, _ := db.ListChannelMembers("T1", "C1")
	if len(got) != 2 {
		t.Errorf("members lost: %v", got)
	}
	// Meta zeroed.
	ts, ok, _ := db.GetChannelMembershipMeta("T1", "C1")
	if !ok || ts != 0 {
		t.Errorf("meta = (%d, %v), want (0, true)", ts, ok)
	}
}

func TestZeroChannelMembershipMetaMissingIsNoop(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()

	if err := db.ZeroChannelMembershipMeta("T1", "C_NEVER_FETCHED"); err != nil {
		t.Errorf("zeroing nonexistent meta should be noop; got %v", err)
	}
}

func TestChannelMembersScopedByWorkspace(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()
	// Add a second workspace so the FK on channels would have somewhere to point if we used it.
	_ = db.UpsertWorkspace(Workspace{ID: "T2", Name: "Other"})

	_ = db.UpsertChannelMember("T1", "C1", "U1", 100)
	_ = db.UpsertChannelMember("T2", "C1", "U2", 100)

	got1, _ := db.ListChannelMembers("T1", "C1")
	got2, _ := db.ListChannelMembers("T2", "C1")
	if len(got1) != 1 || got1[0] != "U1" {
		t.Errorf("T1/C1 = %v, want [U1]", got1)
	}
	if len(got2) != 1 || got2[0] != "U2" {
		t.Errorf("T2/C1 = %v, want [U2]", got2)
	}
}
