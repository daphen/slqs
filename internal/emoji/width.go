// Package emoji provides utilities for measuring emoji display width
// when emoji are rendered as inline images via the kitty graphics
// protocol. When image mode is inactive, Width() falls back to
// lipgloss.Width().
package emoji

import (
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/rivo/uniseg"
)

// Width returns the rendered cell width of s.
//
// ANSI escape sequences are stripped before measurement (matching
// lipgloss.Width's behavior). For pure ASCII or when image mode is
// inactive, delegates to lipgloss.Width(). When image mode is active,
// each grapheme cluster recognized as an emoji image contributes the
// configured cell footprint (typically 2) and all other clusters fall
// through to lipgloss.
func Width(s string) int {
	// Strip ANSI escape sequences first. Without this, uniseg would
	// segment ESC bytes and parameter bytes as individual graphemes,
	// each measuring as width 1 — wildly inflating the result for any
	// styled string from lipgloss.
	stripped := ansi.Strip(s)

	if !containsNonASCII(stripped) {
		return lipgloss.Width(stripped)
	}
	if !ImageModeActive() {
		return lipgloss.Width(stripped)
	}

	imageCells := ImageModeCells()
	total := 0
	gr := uniseg.NewGraphemes(stripped)
	for gr.Next() {
		cluster := gr.Str()
		if isKnownEmojiCluster(cluster) {
			total += imageCells
			continue
		}
		total += lipgloss.Width(cluster)
	}
	return total
}

// containsNonASCII returns true if s has any byte ≥ 0x80.
func containsNonASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return true
		}
	}
	return false
}
