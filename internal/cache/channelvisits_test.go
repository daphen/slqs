package cache

import (
	"testing"
	"time"
)

func TestRecordAndGetChannelVisit(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("opening db: %v", err)
	}
	defer db.Close()

	if err := db.RecordChannelVisit("T1", "C1"); err != nil {
		t.Fatalf("record: %v", err)
	}
	if err := db.RecordChannelVisit("T1", "C2"); err != nil {
		t.Fatalf("record: %v", err)
	}

	visits, err := db.GetChannelVisits("T1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if len(visits) != 2 {
		t.Fatalf("want 2 entries, got %d", len(visits))
	}
	if visits["C1"] == 0 || visits["C2"] == 0 {
		t.Fatalf("expected non-zero last_visited, got %+v", visits)
	}
}

func TestRecordChannelVisitLastWriteWins(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("opening db: %v", err)
	}
	defer db.Close()

	if err := db.RecordChannelVisit("T1", "C1"); err != nil {
		t.Fatalf("record: %v", err)
	}
	first, _ := db.GetChannelVisits("T1")
	firstTS := first["C1"]

	// Sleep just over a second so the unix-second timestamp definitely advances.
	time.Sleep(1100 * time.Millisecond)

	if err := db.RecordChannelVisit("T1", "C1"); err != nil {
		t.Fatalf("record: %v", err)
	}
	second, _ := db.GetChannelVisits("T1")
	if second["C1"] <= firstTS {
		t.Fatalf("expected later timestamp on second visit; first=%d second=%d", firstTS, second["C1"])
	}
}

func TestGetChannelVisitsIsolatesWorkspaces(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatalf("opening db: %v", err)
	}
	defer db.Close()

	if err := db.RecordChannelVisit("T1", "C1"); err != nil {
		t.Fatalf("record: %v", err)
	}
	if err := db.RecordChannelVisit("T2", "C2"); err != nil {
		t.Fatalf("record: %v", err)
	}

	t1, _ := db.GetChannelVisits("T1")
	t2, _ := db.GetChannelVisits("T2")

	if _, ok := t1["C1"]; !ok {
		t.Errorf("expected T1 to contain C1, got %+v", t1)
	}
	if _, ok := t1["C2"]; ok {
		t.Errorf("expected T1 to NOT contain C2, got %+v", t1)
	}
	if _, ok := t2["C2"]; !ok {
		t.Errorf("expected T2 to contain C2, got %+v", t2)
	}
	if _, ok := t2["C1"]; ok {
		t.Errorf("expected T2 to NOT contain C1, got %+v", t2)
	}
}
