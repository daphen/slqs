package main

import (
	"strings"
	"testing"
)

func TestRichTextSectionAttachmentMention(t *testing.T) {
	els := []any{
		map[string]any{"type": "text", "text": "Hi Team, can I get an update on:  "},
		map[string]any{"type": "attachment_mention",
			"url":  "https://linear.app/lovable/issue/EVERY-2620/x",
			"text": "Claude Design import rejects workspace Editors"},
	}
	got := richTextSection(els)
	want := "Hi Team, can I get an update on:  [Claude Design import rejects workspace Editors](https://linear.app/lovable/issue/EVERY-2620/x)"
	if got != want {
		t.Errorf("attachment_mention render:\n got=%q\nwant=%q", got, want)
	}
	// a bracket in the title must not break the [label](url) form
	els2 := []any{map[string]any{"type": "attachment_mention", "url": "https://x/y", "text": "a [b] c"}}
	if g := richTextSection(els2); strings.Contains(g, "[b]") {
		t.Errorf("unescaped ']' in title: %q", g)
	}
}
