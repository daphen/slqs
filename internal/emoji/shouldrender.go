package emoji

import "strings"

// ShouldRenderUnicode reports whether the resolved Unicode form of an
// emoji is safe to render as a glyph. Returns true iff the string
// contains exactly one codepoint. Any multi-codepoint sequence —
// including base+VS16 (`❤️`, `⚠️`, `🌩️`), ZWJ sequences,
// regional-indicator flag pairs, and skin-tone modifiers — returns
// false.
//
// VS16 (U+FE0F) was previously treated as a "safe composition" but
// field experience disagreed: many terminal+font combos render
// VS16-anchored emoji from the legacy blocks (U+2600-2BFF and
// U+1F300-1F5FF) at a different visual width than lipgloss reports,
// breaking border alignment. Dropping the VS16 carve-out is the
// pragmatic tradeoff: lose the colorful presentation for `:heart:`,
// `:warning:`, `:lightning:`, etc., gain reliable layout.
//
// Trailing whitespace is ignored — kyokomi/emoji's Sprint appends a
// trailing space after each resolved emoji and callers occasionally
// pass that form. Empty strings (after trim) return false.
func ShouldRenderUnicode(s string) bool {
	s = strings.TrimRight(s, " \t")
	if s == "" {
		return false
	}
	runes := []rune(s)
	return len(runes) == 1
}
