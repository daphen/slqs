package main

import (
	"strings"
	"testing"
)

func TestTextFromBlocksAttachmentBlocks(t *testing.T) {
	// Linear-style: real content lives in attachment.blocks, not top-level.
	raw := `{"text":"","attachments":[{"fallback":"PX-2664 title","blocks":[
		{"type":"section","text":{"type":"mrkdwn","text":"<https://linear.app/x|PX-2664 title>"}},
		{"type":"section","text":{"type":"mrkdwn","text":"A customer needs X restored."}},
		{"type":"context","elements":[{"type":"mrkdwn","text":"Bug · P1"}]}
	]}]}`
	got := textFromBlocks(raw)
	for _, want := range []string{"PX-2664 title", "A customer needs X restored.", "Bug · P1"} {
		if !strings.Contains(got, want) {
			t.Errorf("attachment blocks: missing %q in:\n%s", want, got)
		}
	}
}

func TestTextFromBlocksTopLevelStillWorks(t *testing.T) {
	raw := `{"text":"","blocks":[{"type":"section","text":{"type":"mrkdwn","text":"top level section"}}]}`
	if got := textFromBlocks(raw); !strings.Contains(got, "top level section") {
		t.Errorf("top-level regression: %q", got)
	}
}

func TestRichTextSectionAttachmentMention(t *testing.T) {
	els := []any{
		map[string]any{"type": "text", "text": "Hi Team, can I get an update on:  "},
		map[string]any{"type": "attachment_mention",
			"url":          "https://linear.app/lovable/issue/EVERY-2620/x",
			"text":         "Claude Design import rejects workspace Editors",
			"product_name": "Linear"},
	}
	got := richTextSection(els)
	want := "Hi Team, can I get an update on:  [Linear: Claude Design import rejects workspace Editors](https://linear.app/lovable/issue/EVERY-2620/x)"
	if got != want {
		t.Errorf("attachment_mention render:\n got=%q\nwant=%q", got, want)
	}
	// a bracket in the title must not break the [label](url) form
	els2 := []any{map[string]any{"type": "attachment_mention", "url": "https://x/y", "text": "a [b] c"}}
	if g := richTextSection(els2); strings.Contains(g, "[b]") {
		t.Errorf("unescaped ']' in title: %q", g)
	}
}
