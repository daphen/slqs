package main

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/slack-go/slack"
)

// A Slack archive permalink: https://<team>.slack.com/archives/<CHANNEL>/p<ts-digits>
// The p<digits> encodes the ts — p1785441758131699 -> 1785441758.131699 (a decimal
// point 6 from the end). thread_ts, when the link is a thread message, is a query arg.
var (
	rePermalink = regexp.MustCompile(`https?://([a-z0-9-]+)\.slack\.com/archives/([A-Z0-9]+)/p(\d+)(?:\?[^\s>|)]*)?`)
	reThreadTS  = regexp.MustCompile(`thread_ts=(\d+\.\d+)`)
)

const (
	permalinkFetchTimeout = 8 * time.Second
	maxInlineReplies      = 3
	previewLineCap        = 160
)

type permalink struct {
	subdomain string
	channelID string
	ts        string
	threadTS  string // set only when the link carries a thread_ts (points into a thread)
	url       string // the exact matched URL, kept intact so `o`/click still works
}

// previewEntry is one cached resolution. `full` (head + parent + replies) is used
// for a bare link; `repliesOnly` (just the ↳ lines) is used when the host already
// shows the parent — a shared-message card — so the parent isn't rendered twice.
// `parentKey` is a stable prefix of the parent body used to detect that case.
type previewEntry struct {
	full        string
	repliesOnly string
	parentKey   string
}

func decodeTS(digits string) string {
	if len(digits) <= 6 {
		return digits
	}
	return digits[:len(digits)-6] + "." + digits[len(digits)-6:]
}

// parsePermalinks pulls every archive permalink out of a text blob (message body
// or a share's FromURL, which shareQuotes has already folded into the body).
func parsePermalinks(text string) []permalink {
	var out []permalink
	for _, m := range rePermalink.FindAllStringSubmatch(text, -1) {
		pl := permalink{subdomain: m[1], channelID: m[2], ts: decodeTS(m[3]), url: m[0]}
		if tt := reThreadTS.FindStringSubmatch(m[0]); tt != nil {
			pl.threadTS = tt[1]
		}
		out = append(out, pl)
	}
	return out
}

func targetKey(ch, ts string) string { return ch + "|" + ts }

// permalinkPreviews returns the quoted previews for any archive permalinks in src
// that are already resolved (cache hit), and kicks a background fetch for the rest —
// registering (hostChannel, hostTS) as a waiter so the host message is re-broadcast
// once its preview lands. Rendered as shareQuotes-shaped mrkdwn so d.render styles it.
func (d *daemon) permalinkPreviews(host *workspace, hostChannel, hostTS, src string) string {
	pls := parsePermalinks(src)
	if len(pls) == 0 {
		return ""
	}
	var blocks []string
	seen := map[string]bool{}
	for _, pl := range pls {
		tw := d.workspaceForPermalink(pl)
		if tw == nil {
			continue // a workspace we're not logged into — can't fetch, leave the plain link
		}
		if pl.channelID == hostChannel && pl.ts == hostTS {
			continue // a link to the message itself
		}
		key := targetKey(pl.channelID, pl.ts)
		if seen[key] {
			continue
		}
		seen[key] = true
		if e, ok := d.previewLookup(key); ok {
			block := e.full
			if e.parentKey != "" && strings.Contains(src, e.parentKey) {
				block = e.repliesOnly // parent already shown by shareQuotes — add only the replies
			}
			if block != "" {
				blocks = append(blocks, block)
			}
			continue
		}
		d.previewFetchAsync(tw, pl, hostChannel, hostTS)
	}
	return strings.Join(blocks, "\n")
}

// workspaceForPermalink finds the connected workspace that can fetch a permalink:
// the channel's owner if we know it, else a team whose subdomain matches the link.
func (d *daemon) workspaceForPermalink(pl permalink) *workspace {
	if w := d.idIndex[pl.channelID]; w != nil {
		return w
	}
	for _, w := range d.wsList {
		if w.client != nil && strings.EqualFold(w.client.TeamSubdomain(), pl.subdomain) {
			return w
		}
	}
	return nil
}

func (d *daemon) previewLookup(key string) (previewEntry, bool) {
	d.prevMu.Lock()
	defer d.prevMu.Unlock()
	e, ok := d.prevDone[key]
	return e, ok
}

func (d *daemon) previewFetchAsync(tw *workspace, pl permalink, hostChannel, hostTS string) {
	key := targetKey(pl.channelID, pl.ts)
	host := [2]string{hostChannel, hostTS}
	d.prevMu.Lock()
	if d.prevWait[key] == nil {
		d.prevWait[key] = map[[2]string]bool{}
	}
	d.prevWait[key][host] = true
	if d.prevInfl[key] {
		d.prevMu.Unlock()
		return
	}
	d.prevInfl[key] = true
	d.prevMu.Unlock()

	go func() {
		e := d.buildPreview(tw, pl) // zero entry on failure — cached so we don't refetch
		d.prevMu.Lock()
		d.prevDone[key] = e
		delete(d.prevInfl, key)
		waiters := d.prevWait[key]
		delete(d.prevWait, key)
		d.prevMu.Unlock()
		for h := range waiters {
			d.rebroadcastHost(h[0], h[1])
		}
	}()
}

// buildPreview fetches the linked message (cache-first, then live) plus, when it's
// a thread root, its replies, and renders the quote block. Runs off the render path.
func (d *daemon) buildPreview(tw *workspace, pl permalink) previewEntry {
	ctx, cancel := context.WithTimeout(d.ctx, permalinkFetchTimeout)
	defer cancel()

	target, ok := d.fetchOne(ctx, tw, pl.channelID, pl.ts)
	if !ok {
		return previewEntry{}
	}
	var replies []slack.Message
	isRoot := pl.threadTS == "" || pl.threadTS == pl.ts
	if isRoot && target.ReplyCount > 0 {
		if r, err := tw.client.GetReplies(ctx, pl.channelID, pl.ts); err == nil && len(r) > 0 {
			replies = r[1:] // element 0 is the parent
		}
	}
	return d.renderPreview(tw, pl.url, target, replies)
}

// fetchOne resolves a single message by (channel, ts): cache first, then a live
// history window around ts (the same call jump-to-message uses).
func (d *daemon) fetchOne(ctx context.Context, tw *workspace, channelID, ts string) (slack.Message, bool) {
	if cm, err := d.writeDB.GetMessage(channelID, ts); err == nil {
		if m, ok := messageFromRaw(cm.RawJSON); ok {
			return m, true
		}
		return slack.Message{Msg: slack.Msg{Timestamp: cm.TS, Text: cm.Text, User: cm.UserID, ReplyCount: cm.ReplyCount, ThreadTimestamp: cm.ThreadTS}}, true
	}
	msgs, err := tw.client.GetHistoryAround(ctx, channelID, ts, 5)
	if err != nil {
		return slack.Message{}, false
	}
	for _, m := range msgs {
		if m.Timestamp == ts {
			return m, true
		}
	}
	return slack.Message{}, false
}

func messageFromRaw(raw string) (slack.Message, bool) {
	if raw == "" {
		return slack.Message{}, false
	}
	var m slack.Message
	if err := json.Unmarshal([]byte(raw), &m); err != nil || m.Timestamp == "" {
		return slack.Message{}, false
	}
	return m, true
}

// renderPreview builds the shareQuotes-shaped quote block. It returns both a `full`
// form (head + parent body + up to maxInlineReplies `> ↳` reply lines, `+K more`
// tail beyond) for a bare link, and a `repliesOnly` form (just the reply lines) for
// when the host is a shared-message card that already shows the parent. Author ids
// resolve via the target workspace (resolveUnknownUsers pulls in externals). The
// permalink is rendered as a compact `↗` label so the raw URL isn't dumped as text.
func (d *daemon) renderPreview(tw *workspace, url string, m slack.Message, replies []slack.Message) previewEntry {
	ids := []string{authorOf(m)}
	shown := replies
	extra := 0
	if len(shown) > maxInlineReplies {
		extra = len(shown) - maxInlineReplies
		shown = shown[:maxInlineReplies]
	}
	for _, r := range shown {
		ids = append(ids, authorOf(r))
	}
	d.resolveUnknownUsers(tw, ids)

	var reply strings.Builder
	for _, r := range shown {
		reply.WriteString("> ↳ *" + previewAuthor(tw, r) + "* " + oneLine(displayText(r)) + "\n")
	}
	if extra > 0 {
		reply.WriteString(fmt.Sprintf("> ↳ +%d more\n", extra))
	}
	repliesOnly := strings.TrimRight(reply.String(), "\n")

	parentLines := strings.Split(displayText(m), "\n")
	var full strings.Builder
	full.WriteString("> ↰ *" + previewAuthor(tw, m) + "*")
	if url != "" {
		full.WriteString(" · [↗](" + url + ")")
	}
	for _, l := range parentLines {
		full.WriteString("\n> " + l)
	}
	if repliesOnly != "" {
		full.WriteString("\n" + repliesOnly)
	}

	return previewEntry{full: full.String(), repliesOnly: repliesOnly, parentKey: parentKey(parentLines)}
}

// parentKey is a stable ~60-char prefix of the parent's first real line, used to
// detect that the host already renders the parent (a shared-message card).
func parentKey(lines []string) string {
	for _, l := range lines {
		if s := strings.TrimSpace(l); s != "" {
			if len(s) > 60 {
				s = s[:60]
			}
			return s
		}
	}
	return ""
}

func previewAuthor(tw *workspace, m slack.Message) string {
	if n := tw.users[authorOf(m)]; n != "" {
		return n
	}
	if m.Username != "" {
		return m.Username
	}
	return "someone"
}

// oneLine collapses a reply to a single tidy line for the inline `> ↳` form.
func oneLine(s string) string {
	s = strings.TrimSpace(strings.Join(strings.Fields(s), " "))
	if len(s) > previewLineCap {
		s = strings.TrimSpace(s[:previewLineCap]) + "…"
	}
	return s
}

// rebroadcastHost re-emits a host message over the existing {type:"message"} path
// so the client replaces it in place (QML ingest() matches on ts) once a late
// permalink preview has resolved — no new socket type or UI delegate needed.
func (d *daemon) rebroadcastHost(hostChannel, hostTS string) {
	w := d.idIndex[hostChannel]
	if w == nil {
		return
	}
	m, err := d.writeDB.GetMessage(hostChannel, hostTS)
	if err != nil {
		return
	}
	d.broadcast(map[string]any{
		"type": "message", "workspace": w.teamID, "channel": hostChannel, "thread": m.ThreadTS,
		"mention": w.isMention(w.chanKind[hostChannel], m.Text),
		"msg":     d.msgFromRaw(w, hostChannel, m.UserID, m.TS, m.Text, m.ReplyCount, m.RawJSON),
	})
}
