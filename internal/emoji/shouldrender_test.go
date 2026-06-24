package emoji

import "testing"

func TestShouldRenderUnicode(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  bool
	}{
		// Single codepoint, emoji presentation.
		{"single emoji raised hands", "\U0001F64C", true},
		{"single emoji rainbow", "\U0001F308", true},
		{"single emoji fire", "\U0001F525", true},
		// Single non-emoji codepoint (rule is structural; harmless).
		{"single ascii letter", "a", true},
		{"single misc symbol", "\u2603", true},
		// Single base codepoint + VS16. Previously rendered as glyph;
		// now falls back to shortcode because font support for
		// VS16 emoji presentation in legacy blocks is inconsistent.
		{"heart + VS16", "\u2764\uFE0F", false},
		{"warning + VS16", "\u26A0\uFE0F", false},
		{"flag base + VS16", "\U0001F3F3\uFE0F", false},
		// Multi-codepoint composition (the cases the bug is about).
		{"ZWJ pride flag", "\U0001F3F3\uFE0F\u200D\U0001F308", false},
		{"ZWJ family", "\U0001F468\u200D\U0001F469\u200D\U0001F467", false},
		{"regional indicator pair US", "\U0001F1FA\U0001F1F8", false},
		{"skin-tone modifier", "\U0001F44D\U0001F3FD", false},
		{"base + VS16 + extra codepoint", "\u2764\uFE0F\u200D\U0001F525", false},
		// Edge cases.
		{"empty string", "", false},
		{"two ascii letters", "ab", false},
		// Defensive: callers occasionally pass kyokomi's trailing-space form.
		{"single emoji with trailing space", "\U0001F308 ", true},
		{"ZWJ with trailing space", "\U0001F3F3\uFE0F\u200D\U0001F308 ", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ShouldRenderUnicode(c.input)
			if got != c.want {
				t.Errorf("ShouldRenderUnicode(%q) = %v, want %v", c.input, got, c.want)
			}
		})
	}
}
