package image

import (
	"image"
	"testing"
)

func TestFetchRequest_HasReqID(t *testing.T) {
	r := FetchRequest{
		Key:    "k",
		URL:    "https://example.com/x.png",
		Target: image.Pt(100, 100),
		ReqID:  42,
	}
	if r.ReqID != 42 {
		t.Fatalf("ReqID round-trip failed: %d", r.ReqID)
	}
}
