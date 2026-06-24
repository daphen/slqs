package emoji

import (
	"testing"
)

func TestWidthASCIIBypass(t *testing.T) {
	if got := Width("hello"); got != 5 {
		t.Errorf("Width(\"hello\") = %d, want 5", got)
	}
	if got := Width(""); got != 0 {
		t.Errorf("Width(\"\") = %d, want 0", got)
	}
	if got := Width("a"); got != 1 {
		t.Errorf("Width(\"a\") = %d, want 1", got)
	}
}

func TestWidthStripsANSI(t *testing.T) {
	// ANSI escapes must be stripped before width measurement.
	if got := Width("\x1b[31mhello\x1b[0m"); got != 5 {
		t.Errorf("Width(ansi 'hello') = %d, want 5", got)
	}
}

func TestWidth_ImageMode_KnownEmojiClusters(t *testing.T) {
	resetImageMode()
	t.Cleanup(func() {
		resetImageMode()
	})

	SetImageMode(true, 2)

	cases := []struct {
		name string
		in   string
		want int
	}{
		// Each single emoji reports the image-mode footprint (2 cells).
		{"single thumb", "\U0001F44D", 2},
		{"VS16 sequence", "\u2764\uFE0F", 2},
		{"ZWJ sequence", "\U0001F468\u200D\U0001F680", 2},
		{"regional indicator pair", "\U0001F1FA\U0001F1F8", 2},

		// Mixed text + emoji: emoji = 2, plus the ASCII run.
		{"text + emoji", "hi \U0001F44D", 5}, // "hi " (3) + emoji (2)
		{"emoji + text", "\U0001F44D hi", 5}, // emoji (2) + " hi" (3)

		// Two adjacent emoji.
		{"emoji + emoji", "\U0001F44D\u2764\uFE0F", 4},

		// Pure ASCII: lipgloss path unchanged.
		{"ascii only", "hello", 5},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Width(c.in)
			if got != c.want {
				t.Errorf("Width(%q) = %d, want %d", c.in, got, c.want)
			}
		})
	}
}

func TestWidth_ImageMode_OneCellOverride(t *testing.T) {
	resetImageMode()
	t.Cleanup(func() {
		resetImageMode()
	})

	SetImageMode(true, 1)
	if got := Width("\U0001F44D"); got != 1 {
		t.Errorf("Width(thumb) with cells=1 = %d, want 1", got)
	}
	if got := Width("hi \U0001F44D"); got != 4 {
		t.Errorf("Width('hi ' + thumb) with cells=1 = %d, want 4 ('hi ' + 1)", got)
	}
}

func TestWidth_ImageMode_InactiveFallsThrough(t *testing.T) {
	resetImageMode()
	t.Cleanup(func() {
		resetImageMode()
	})

	// Mode is inactive — should NOT force 2-cell width for emoji
	// clusters; behavior comes from lipgloss fallback. Confirm by
	// checking ASCII unaffected and ImageModeActive is false so the
	// image-mode branch is not taken.
	if got := Width("hello"); got != 5 {
		t.Errorf("Width(ascii) with image-mode off = %d, want 5", got)
	}
	if ImageModeActive() {
		t.Fatalf("ImageModeActive() = true after resetImageMode()")
	}
}
