package emoji

import "sync"

// Image-mode is a process-global flag that records whether emoji
// should be rendered as PNG images via the kitty graphics protocol.
// When active, the width math, render, and shouldn't-probe decisions
// all branch off this single value.
//
// Set once at startup (cmd/slk/main.go) after the user's config has
// been loaded and the terminal's image protocol has been detected.
// Not safe to toggle dynamically — UI surfaces snapshot the value
// at View() time but the kitty image upload pipeline holds session
// state that isn't designed for mid-session protocol changes.
var (
	imageModeMu     sync.RWMutex
	imageModeActive bool
	imageModeCells  = 2
)

// SetImageMode records whether emoji should be rendered as images.
// cells must be 1 or 2; other values clamp to 2. Safe to call at
// most once during process startup, before bubbletea begins.
func SetImageMode(active bool, cells int) {
	if cells != 1 && cells != 2 {
		cells = 2
	}
	imageModeMu.Lock()
	defer imageModeMu.Unlock()
	imageModeActive = active
	imageModeCells = cells
}

// ImageModeActive reports whether emoji-as-images is enabled.
// Cheap RLock under the hood; safe to call from any goroutine.
func ImageModeActive() bool {
	imageModeMu.RLock()
	defer imageModeMu.RUnlock()
	return imageModeActive
}

// ImageModeCells returns the per-emoji cell footprint (typically 2).
// Returns 2 when image mode is inactive; callers should gate on
// ImageModeActive before using this value.
func ImageModeCells() int {
	imageModeMu.RLock()
	defer imageModeMu.RUnlock()
	return imageModeCells
}

// resetImageMode clears the mode. Test-only helper.
func resetImageMode() {
	imageModeMu.Lock()
	defer imageModeMu.Unlock()
	imageModeActive = false
	imageModeCells = 2
}
