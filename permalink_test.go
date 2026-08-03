package main

import (
	"strings"
	"testing"

	"github.com/slack-go/slack"
)

func TestDecodeTS(t *testing.T) {
	cases := map[string]string{
		"1785441758131699": "1785441758.131699",
		"131699":           "131699",
		"12345":            "12345",
	}
	for in, want := range cases {
		if got := decodeTS(in); got != want {
			t.Errorf("decodeTS(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParsePermalinks(t *testing.T) {
	src := "see <https://lovable-dev.slack.com/archives/C091U1D8HMZ/p1785441758131699?thread_ts=1785441758.131699&cid=C091U1D8HMZ> and " +
		"https://foo.slack.com/archives/C0ABC/p1700000000000001 plus https://github.com/x/y/pull/1 and https://foo.example.com/archives/C1/p123"
	got := parsePermalinks(src)
	if len(got) != 2 {
		t.Fatalf("expected 2 archive permalinks, got %d: %+v", len(got), got)
	}
	if got[0].channelID != "C091U1D8HMZ" || got[0].ts != "1785441758.131699" {
		t.Errorf("first: got channel=%q ts=%q", got[0].channelID, got[0].ts)
	}
	if got[0].threadTS != "1785441758.131699" {
		t.Errorf("first: expected thread_ts, got %q", got[0].threadTS)
	}
	if got[0].subdomain != "lovable-dev" {
		t.Errorf("first: subdomain = %q", got[0].subdomain)
	}
	if got[1].channelID != "C0ABC" || got[1].ts != "1700000000.000001" || got[1].threadTS != "" {
		t.Errorf("second: got %+v", got[1])
	}
}

func TestParsePermalinksNone(t *testing.T) {
	for _, s := range []string{"", "no links here", "https://slack.com/help", "https://x.slack.com/archives/C1"} {
		if got := parsePermalinks(s); len(got) != 0 {
			t.Errorf("parsePermalinks(%q) = %+v, want none", s, got)
		}
	}
}

func TestOneLine(t *testing.T) {
	if got := oneLine("hello\n  world\tthere "); got != "hello world there" {
		t.Errorf("oneLine collapse = %q", got)
	}
	long := strings.Repeat("a", 200)
	got := oneLine(long)
	if len([]rune(got)) > previewLineCap+1 || !strings.HasSuffix(got, "…") {
		t.Errorf("oneLine cap failed: len=%d suffix ok=%v", len([]rune(got)), strings.HasSuffix(got, "…"))
	}
}

func TestFirstLinkFindsMarkdownAndAngle(t *testing.T) {
	// a [↗](url) preview link must feed the `o` keybind (msg.link)
	if got := firstLink("hi > ↰ *D* · [↗](https://x.slack.com/archives/C/p1?thread_ts=1.2)"); got != "https://x.slack.com/archives/C/p1?thread_ts=1.2" {
		t.Errorf("markdown link: got %q", got)
	}
	// an earlier angle link still wins over a later markdown link
	if got := firstLink("see <https://a.example/x> and [y](https://b.example/z)"); got != "https://a.example/x" {
		t.Errorf("angle-first: got %q", got)
	}
	if got := firstLink("no links"); got != "" {
		t.Errorf("none: got %q", got)
	}
}

func msg(user, text string, replyCount int) slack.Message {
	return slack.Message{Msg: slack.Msg{User: user, Text: text, ReplyCount: replyCount}}
}

func TestRenderPreviewParentAndReplies(t *testing.T) {
	d := &daemon{userMiss: map[string]bool{}}
	w := &workspace{users: map[string]string{"U1": "Daniel", "U2": "Roman"}}
	parent := msg("U1", "Issue: project details show Location", 2)
	replies := []slack.Message{msg("U2", "#team-everywhere?", 0), msg("U1", "Might be?", 0)}
	e := d.renderPreview(w, "https://x.slack.com/archives/C/p1", parent, replies)

	for _, want := range []string{"> ↰ *Daniel*", "· [↗](https://x.slack.com/archives/C/p1)", "> Issue: project details show Location", "> ↳ *Roman* #team-everywhere?", "> ↳ *Daniel* Might be?"} {
		if !strings.Contains(e.full, want) {
			t.Errorf("full missing %q in:\n%s", want, e.full)
		}
	}
	if strings.Contains(e.full, "more") {
		t.Errorf("no +K more expected for 2 replies:\n%s", e.full)
	}
	// repliesOnly must carry the replies but NOT the head/parent (dedup case).
	if strings.Contains(e.repliesOnly, "↰") || strings.Contains(e.repliesOnly, "Issue:") {
		t.Errorf("repliesOnly should exclude head/parent:\n%s", e.repliesOnly)
	}
	if !strings.Contains(e.repliesOnly, "> ↳ *Roman* #team-everywhere?") {
		t.Errorf("repliesOnly missing reply line:\n%s", e.repliesOnly)
	}
	if !strings.HasPrefix("Issue: project details show Location", e.parentKey) || e.parentKey == "" {
		t.Errorf("parentKey should be a prefix of the parent body, got %q", e.parentKey)
	}
}

func TestRenderPreviewCapsReplies(t *testing.T) {
	d := &daemon{userMiss: map[string]bool{}}
	w := &workspace{users: map[string]string{"U1": "Daniel"}}
	parent := msg("U1", "parent", 5)
	var replies []slack.Message
	for i := 0; i < 5; i++ {
		replies = append(replies, msg("U1", "reply", 0))
	}
	e := d.renderPreview(w, "", parent, replies)
	if strings.Count(e.full, "> ↳ *Daniel* reply") != maxInlineReplies {
		t.Errorf("expected %d reply lines, got:\n%s", maxInlineReplies, e.full)
	}
	if !strings.Contains(e.full, "+2 more") {
		t.Errorf("expected '+2 more' tail, got:\n%s", e.full)
	}
	if strings.Contains(e.full, " · <") {
		t.Errorf("empty url should omit the ' · <…>' head, got:\n%s", e.full)
	}
}
