package emoji

import "testing"

func TestImageMode_DefaultsToInactive(t *testing.T) {
	resetImageMode()
	if ImageModeActive() {
		t.Errorf("ImageModeActive() should be false by default")
	}
	if ImageModeCells() != 2 {
		t.Errorf("ImageModeCells() default = %d, want 2", ImageModeCells())
	}
}

func TestImageMode_SetActivates(t *testing.T) {
	resetImageMode()
	SetImageMode(true, 2)
	if !ImageModeActive() {
		t.Errorf("after SetImageMode(true, 2): ImageModeActive() = false, want true")
	}
	if ImageModeCells() != 2 {
		t.Errorf("ImageModeCells() = %d, want 2", ImageModeCells())
	}
}

func TestImageMode_ClampsCells(t *testing.T) {
	resetImageMode()
	for _, c := range []int{0, -1, 3, 99} {
		SetImageMode(true, c)
		if ImageModeCells() != 2 {
			t.Errorf("SetImageMode(true, %d): cells = %d, want clamp to 2", c, ImageModeCells())
		}
	}
	SetImageMode(true, 1)
	if ImageModeCells() != 1 {
		t.Errorf("SetImageMode(true, 1): cells = %d, want 1", ImageModeCells())
	}
}

func TestImageMode_DeactivateRoundTrip(t *testing.T) {
	resetImageMode()
	SetImageMode(true, 2)
	SetImageMode(false, 2)
	if ImageModeActive() {
		t.Errorf("after SetImageMode(false, _): ImageModeActive() = true, want false")
	}
}
