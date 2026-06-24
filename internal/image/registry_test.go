package image

import (
	"image"
	"testing"
)

func TestRegistry_AssignsStableIDs(t *testing.T) {
	r := NewRegistry()
	id1, fresh1 := r.Lookup("file-A", image.Pt(40, 20))
	if !fresh1 {
		t.Error("expected fresh on first lookup")
	}
	if id1 == 0 {
		t.Error("expected non-zero ID")
	}

	// Simulate a successful upload of the freshly-minted ID. Without
	// this, the registry assumes the bytes never reached the terminal
	// and the next Lookup will still report fresh=true so the caller
	// re-encodes and re-uploads. See TestRegistry_FreshUntilUploaded.
	r.MarkUploaded(id1)

	id2, fresh2 := r.Lookup("file-A", image.Pt(40, 20))
	if fresh2 {
		t.Error("expected not fresh on repeat after MarkUploaded")
	}
	if id2 != id1 {
		t.Errorf("expected stable ID %d, got %d", id1, id2)
	}
}

// TestRegistry_FreshUntilUploaded asserts the upload-status semantic
// added to fix the messages-pane cache-rebuild race: until
// MarkUploaded(id) is called, repeated Lookups for the same
// (key, target) must keep returning fresh=true so the caller knows it
// still needs to encode and transmit bytes. Without this, kitty
// placement cells can reference an image_id the terminal never
// received bytes for, leaving the image as blank cells.
func TestRegistry_FreshUntilUploaded(t *testing.T) {
	r := NewRegistry()
	target := image.Pt(40, 20)

	id1, fresh1 := r.Lookup("file-A", target)
	if !fresh1 {
		t.Fatal("expected fresh=true on first Lookup")
	}

	// Caller mints an upload closure but never fires it (cache
	// invalidation discards the viewEntry). The registry must still
	// report fresh=true on the next Lookup.
	id2, fresh2 := r.Lookup("file-A", target)
	if !fresh2 {
		t.Error("expected fresh=true on second Lookup before MarkUploaded")
	}
	if id2 != id1 {
		t.Errorf("ID should remain stable; got %d vs %d", id2, id1)
	}

	r.MarkUploaded(id1)

	_, fresh3 := r.Lookup("file-A", target)
	if fresh3 {
		t.Error("expected fresh=false after MarkUploaded")
	}
}

// TestRegistry_MarkUploadedUnknownIDIsNoOp guards against panics when
// MarkUploaded is called for an ID that was never minted (defensive —
// callers should only mark IDs they got from Lookup, but a buggy
// caller shouldn't crash).
func TestRegistry_MarkUploadedUnknownIDIsNoOp(t *testing.T) {
	r := NewRegistry()
	r.MarkUploaded(99999) // must not panic
	// And a subsequent valid Lookup is unaffected.
	id, fresh := r.Lookup("k", image.Pt(1, 1))
	if !fresh {
		t.Error("fresh=true expected for a brand-new key after a stray MarkUploaded")
	}
	if id == 0 {
		t.Error("expected non-zero ID")
	}
}

func TestRegistry_DifferentSizesDifferentIDs(t *testing.T) {
	r := NewRegistry()
	a, _ := r.Lookup("file", image.Pt(40, 20))
	b, _ := r.Lookup("file", image.Pt(20, 10))
	if a == b {
		t.Error("different cell footprints should yield different IDs")
	}
}

func TestRegistry_IDsNonZero(t *testing.T) {
	r := NewRegistry()
	for i := 0; i < 10; i++ {
		id, _ := r.Lookup("k"+string(rune('A'+i)), image.Pt(1, 1))
		if id == 0 {
			t.Errorf("got zero ID at i=%d", i)
		}
	}
}
