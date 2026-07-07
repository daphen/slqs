package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"slqs/internal/cache"

	"github.com/slack-go/slack"
)

// persistMessage upserts a live slack.Message (and its reactions) into the
// cache so reads serve current data even when the websocket missed events.
func (d *daemon) persistMessage(w *workspace, channelID string, m slack.Message) {
	if m.Timestamp == "" {
		return
	}
	authorID := m.User
	if authorID == "" && m.BotID != "" {
		authorID = m.BotID
	}
	raw, _ := json.Marshal(m)
	d.writeDB.UpsertMessage(cache.Message{
		TS: m.Timestamp, ChannelID: channelID, WorkspaceID: w.teamID,
		UserID: authorID, Text: m.Text, ThreadTS: m.ThreadTimestamp,
		ReplyCount: m.ReplyCount, Subtype: m.SubType,
		RawJSON: string(raw), CreatedAt: time.Now().Unix(),
	})
	fresh := map[string]bool{}
	for _, r := range m.Reactions {
		fresh[r.Name] = true
		d.writeDB.UpsertReaction(m.Timestamp, channelID, r.Name, r.Users, r.Count)
	}
	cached, _ := d.writeDB.GetReactions(m.Timestamp, channelID)
	for _, cc := range cached {
		if !fresh[cc.Emoji] {
			d.writeDB.DeleteReaction(m.Timestamp, channelID, cc.Emoji)
		}
	}
}

// imagesFromBlocks pulls image_url out of Block Kit "image" blocks — /giphy posts
// (and other app messages) carry the gif/image there, not in files/attachments.
// Returned as synthetic attachments so imagesJSON's existing gif-detection +
// download + AnimatedImage path handles them unchanged.
func imagesFromBlocks(raw string) []slack.Attachment {
	if raw == "" || !strings.Contains(raw, `"blocks"`) {
		return nil
	}
	var p struct {
		Blocks []map[string]any `json:"blocks"`
	}
	if json.Unmarshal([]byte(raw), &p) != nil {
		return nil
	}
	var out []slack.Attachment
	for _, b := range p.Blocks {
		// Only real image blocks — NOT context-element/accessory images, which are
		// service attribution icons (e.g. the 32px giphy logo) that would blow up.
		if bt, _ := b["type"].(string); bt == "image" {
			if u, _ := b["image_url"].(string); u != "" {
				out = append(out, slack.Attachment{ImageURL: u})
			}
		}
	}
	return out
}

// resolveUnknownUsers fills in names for author IDs missing from the startup
// users.list — external / Slack-Connect participants (and occasionally
// deactivated accounts) — via users.info, so their messages render with a real
// name instead of "someone". Each ID is fetched at most once; misses are
// remembered so a genuinely-unresolvable ID isn't refetched on every render.
// Called before the render loop so the first paint already has real names.
func (d *daemon) resolveUnknownUsers(w *workspace, ids []string) {
	d.mu.Lock()
	var todo []string
	seen := map[string]bool{}
	for _, id := range ids {
		if id == "" || seen[id] || w.users[id] != "" || d.userMiss[id] {
			continue
		}
		seen[id] = true
		todo = append(todo, id)
	}
	d.mu.Unlock()
	if len(todo) == 0 {
		return
	}
	type res struct{ id, name string }
	out := make(chan res, len(todo)) // buffered: senders never block, so a slow lookup can't leak
	sem := make(chan struct{}, 8)
	for _, id := range todo {
		go func(id string) {
			sem <- struct{}{}
			defer func() { <-sem }()
			u, err := w.client.GetUserProfile(id)
			if err != nil || u == nil {
				out <- res{id, ""}
				return
			}
			out <- res{id, nameFor(*u, w.namePref)}
			d.cacheAvatar(*u) // best-effort; shows on a later render if not this one
		}(id)
	}
	// Bound the wait — users.info has no timeout, and a single hung lookup must not
	// block the whole render. Whatever hasn't resolved in time is simply retried on
	// the next open (not marked a miss).
	got := map[string]string{}
	deadline := time.After(5 * time.Second)
	for i := 0; i < len(todo); i++ {
		select {
		case r := <-out:
			got[r.id] = r.name
		case <-deadline:
			i = len(todo)
		case <-d.ctx.Done():
			return
		}
	}
	// Merge copy-on-write (like registerChannel) so lock-free readers never see a
	// half-written map.
	d.mu.Lock()
	nu := make(map[string]string, len(w.users)+len(got))
	for k, v := range w.users {
		nu[k] = v
	}
	for id, name := range got {
		if name != "" {
			nu[id] = name
		} else {
			d.userMiss[id] = true // resolved but nameless (visibility-restricted) — don't refetch
		}
	}
	w.users = nu
	d.mu.Unlock()
}

// resolveMsgAuthors is resolveUnknownUsers for a batch of live messages (only
// real user IDs; bot messages resolve via their embedded username in formatMsg).
func (d *daemon) resolveMsgAuthors(w *workspace, msgs []slack.Message) {
	ids := make([]string, 0, len(msgs))
	for i := range msgs {
		if msgs[i].User != "" {
			ids = append(ids, msgs[i].User)
		}
	}
	d.resolveUnknownUsers(w, ids)
}

// msgFromRaw renders one cache.db row into the message shape Backend.qml wants,
// parsing raw_json for inline images (file uploads + unfurls) and Block Kit text
// (bot messages like swarmia carry their content in blocks, not the text field).
// This is the Go port of export.py's to_msg — cache.db is the single source.
func (d *daemon) msgFromRaw(w *workspace, channelID, userID, ts, text string, replyCount int, raw string) map[string]any {
	var rj struct {
		Files       []slack.File       `json:"files"`
		Attachments []slack.Attachment `json:"attachments"`
		Username    string             `json:"username"`
		SubType     string             `json:"subtype"`
		ThreadTS    string             `json:"thread_ts"`
		Edited      *slack.Edited      `json:"edited"`
	}
	if raw != "" {
		json.Unmarshal([]byte(raw), &rj)
	}
	body := text
	if bt := textFromBlocks(raw); bt != "" {
		body = bt
	}
	// Shared Slack messages ALWAYS render (quoted under the body — a smiley
	// next to a share must not hide it); other attachments (link unfurls)
	// only fill in when the message would otherwise be blank.
	if shares := shareQuotes(rj.Attachments); shares != "" {
		if body != "" {
			body += "\n"
		}
		body += shares
	} else if body == "" {
		body = attachmentText(rj.Attachments)
	}
	author := w.users[userID]
	if author == "" {
		if rj.Username != "" {
			author = rj.Username
		} else {
			author = "someone"
		}
	}
	sec := ts
	if i := strings.IndexByte(ts, '.'); i >= 0 {
		sec = ts[:i]
	}
	s, _ := strconv.ParseInt(sec, 10, 64)
	return map[string]any{
		"author":        author,
		"initials":      initials(author),
		"color":         colorFor(userID),
		"avatar":        d.avatarPath(userID),
		"time":          time.Unix(s, 0).Format("15:04"),
		"text":          d.render(w, body),
		"grouped":       false,
		"reactionsJson": d.reactionsJSONFor(w, channelID, ts),
		"imagesJson":    d.imagesJSON(w, channelID, ts, rj.Files, append(rj.Attachments, imagesFromBlocks(raw)...)),
		"link":          firstLink(body),
		"channelRef":    firstChanRef(body), // first #channel mention id, for `o` to open
		"ts":            ts,
		"reply_count":   replyCount,
		"mine":          userID != "" && userID == w.selfID,
		"subtype":       rj.SubType,   // "thread_broadcast" => also show in the channel timeline
		"thread_ts":     rj.ThreadTS,  // parent ts: lets the channel open the right thread on Enter
		"edited":        rj.Edited != nil,
	}
}

// shareQuotes renders SHARED Slack messages (forwarded/linked chats — the
// footer says "Slack Conversation") as quote lines under the body. Without
// this they only surfaced when the body was empty, so "​:smile: + share"
// showed just the smiley.
func shareQuotes(atts []slack.Attachment) string {
	var parts []string
	for _, a := range atts {
		if !strings.Contains(a.Footer, "Slack Conversation") {
			continue
		}
		t := a.Text
		if t == "" {
			t = a.Fallback
		}
		if a.AuthorName == "" && t == "" {
			continue
		}
		head := "> ↰ *" + a.AuthorName + "*"
		if t != "" {
			lines := strings.Split(t, "\n")
			for i, l := range lines {
				lines[i] = "> " + l
			}
			parts = append(parts, head+"\n"+strings.Join(lines, "\n"))
		} else {
			parts = append(parts, head)
		}
	}
	return strings.Join(parts, "\n")
}

// attachmentText summarizes message attachments (shared messages, link unfurls
// with text) as "Author: title text", joined across attachments.
func attachmentText(atts []slack.Attachment) string {
	var parts []string
	for _, a := range atts {
		var seg []string
		if a.AuthorName != "" {
			seg = append(seg, a.AuthorName+":")
		}
		if a.Title != "" {
			seg = append(seg, a.Title)
		}
		t := a.Text
		if t == "" {
			t = a.Fallback
		}
		if t != "" {
			seg = append(seg, t)
		}
		// Unfurl-only attachments (e.g. Linear issue updates) carry ONLY a
		// URL — the pretty card is client-side hydration we never receive.
		// Render the link so the update is at least visible + clickable.
		if len(seg) == 0 && a.FromURL != "" {
			seg = append(seg, a.FromURL)
		}
		if len(seg) > 0 {
			parts = append(parts, strings.Join(seg, " "))
		}
	}
	return strings.Join(parts, "\n")
}

// richTextSection renders a rich_text_section's inline elements back to Slack mrkdwn,
// so the existing render()+richify pipeline styles them: styled text, mentions,
// channels, emoji, links — emitted as the tokens render() already understands.
func richTextSection(v any) string {
	els, ok := v.([]any)
	if !ok {
		return ""
	}
	var sb strings.Builder
	for _, e := range els {
		em, ok := e.(map[string]any)
		if !ok {
			continue
		}
		switch em["type"] {
		case "text":
			t, _ := em["text"].(string)
			if st, ok := em["style"].(map[string]any); ok {
				if b, _ := st["code"].(bool); b {
					t = "`" + t + "`"
				}
				if b, _ := st["bold"].(bool); b {
					t = "*" + t + "*"
				}
				if b, _ := st["italic"].(bool); b {
					t = "_" + t + "_"
				}
				if b, _ := st["strike"].(bool); b {
					t = "~" + t + "~"
				}
			}
			sb.WriteString(t)
		case "link":
			if u, _ := em["url"].(string); u != "" {
				sb.WriteString("<" + u + ">")
			}
		case "user":
			if u, _ := em["user_id"].(string); u != "" {
				sb.WriteString("<@" + u + ">")
			}
		case "usergroup":
			if g, _ := em["usergroup_id"].(string); g != "" {
				sb.WriteString("<!subteam^" + g + ">")
			}
		case "channel":
			if ch, _ := em["channel_id"].(string); ch != "" {
				sb.WriteString("<#" + ch + ">")
			}
		case "broadcast":
			if r, _ := em["range"].(string); r != "" {
				sb.WriteString("<!" + r + ">")
			}
		case "emoji":
			if n, _ := em["name"].(string); n != "" {
				sb.WriteString(":" + n + ":")
			}
		}
	}
	return sb.String()
}

// richTextRaw concatenates a section's text elements verbatim (no style markers) —
// for code blocks, whose content must stay literal.
func richTextRaw(v any) string {
	els, ok := v.([]any)
	if !ok {
		return ""
	}
	var sb strings.Builder
	for _, e := range els {
		if em, ok := e.(map[string]any); ok {
			if t, _ := em["text"].(string); t != "" {
				sb.WriteString(t)
			}
		}
	}
	return sb.String()
}

// richTextToText reconstructs Slack mrkdwn from a rich_text block, preserving the
// line structure (each section / list item is its own line) that the official client
// shows — the flat top-level text collapses every newline to spaces. "" if no block.
func richTextToText(raw string) string {
	if raw == "" || !strings.Contains(raw, `"rich_text"`) {
		return ""
	}
	var p struct {
		Blocks []map[string]any `json:"blocks"`
	}
	if json.Unmarshal([]byte(raw), &p) != nil {
		return ""
	}
	var lines []string
	for _, b := range p.Blocks {
		if b["type"] != "rich_text" {
			continue
		}
		els, _ := b["elements"].([]any)
		for _, e := range els {
			em, ok := e.(map[string]any)
			if !ok {
				continue
			}
			switch em["type"] {
			case "rich_text_section":
				lines = append(lines, richTextSection(em["elements"]))
			case "rich_text_quote":
				lines = append(lines, "> "+richTextSection(em["elements"]))
			case "rich_text_preformatted":
				lines = append(lines, "```\n"+richTextRaw(em["elements"])+"\n```")
			case "rich_text_list":
				ordered := em["style"] == "ordered"
				items, _ := em["elements"].([]any)
				for i, it := range items {
					im, _ := it.(map[string]any)
					marker := "• "
					if ordered {
						marker = strconv.Itoa(i+1) + ". "
					}
					lines = append(lines, marker+richTextSection(im["elements"]))
				}
			}
		}
	}
	return strings.Join(lines, "\n")
}

// textFromBlocks pulls display text out of Block Kit section/header/context
// blocks so bot messages aren't blank (their top-level text is a flat fallback).
func textFromBlocks(raw string) string {
	if raw == "" || !strings.Contains(raw, `"blocks"`) {
		return ""
	}
	if rt := richTextToText(raw); rt != "" { // user messages: the structured rich_text block
		return rt
	}
	var p struct {
		Blocks []map[string]any `json:"blocks"`
	}
	if json.Unmarshal([]byte(raw), &p) != nil {
		return ""
	}
	txt := func(v any) string {
		if m, ok := v.(map[string]any); ok {
			if s, ok := m["text"].(string); ok {
				return s
			}
		}
		return ""
	}
	var parts []string
	for _, b := range p.Blocks {
		switch b["type"] {
		case "section", "header":
			if t := txt(b["text"]); t != "" {
				parts = append(parts, t)
			}
			if fs, ok := b["fields"].([]any); ok {
				for _, f := range fs {
					if t := txt(f); t != "" {
						parts = append(parts, t)
					}
				}
			}
		case "context":
			if els, ok := b["elements"].([]any); ok {
				var seg []string
				for _, e := range els {
					if t := txt(e); t != "" {
						seg = append(seg, t)
					}
				}
				if len(seg) > 0 {
					parts = append(parts, strings.Join(seg, " "))
				}
			}
		case "actions":
			// Buttons: URL buttons render as label + link (fully usable —
			// they just open a page); action buttons can't be triggered from
			// here (they post to the app's interaction endpoint), so show
			// their labels with an honest pointer instead of Slack's
			// "contains interactive elements" placeholder.
			if els, ok := b["elements"].([]any); ok {
				var seg []string
				hasAction := false
				for _, e := range els {
					m, ok := e.(map[string]any)
					if !ok {
						continue
					}
					label := txt(m["text"])
					if label == "" {
						continue
					}
					if u, _ := m["url"].(string); u != "" {
						seg = append(seg, label+": "+u)
					} else {
						seg = append(seg, "["+label+"]")
						hasAction = true
					}
				}
				if len(seg) > 0 {
					s := strings.Join(seg, "   ")
					if hasAction {
						s += "   (buttons — respond in the Slack app)"
					}
					parts = append(parts, s)
				}
			}
		}
	}
	return strings.Join(parts, "\n")
}

// isMention reports whether a message should surface as a priority (mention/DM):
// any DM, or a channel message that @-mentions self / @here|channel|everyone / a
// user-group self belongs to. Mirrors the notify rules.
func (w *workspace) isMention(kind, text string) bool {
	if kind == "dm" {
		return true
	}
	if strings.Contains(text, "<@"+w.selfID+">") ||
		strings.Contains(text, "<!here>") || strings.Contains(text, "<!channel>") || strings.Contains(text, "<!everyone>") {
		return true
	}
	for _, g := range w.myGroups {
		if strings.Contains(text, "<!subteam^"+g+">") {
			return true
		}
	}
	return false
}

// unreadMentionCount counts unread channel messages (ts>lastRead) that mention self.
func (d *daemon) unreadMentionCount(w *workspace, channelID, lastRead string) int {
	likes := []string{"%<@" + w.selfID + ">%", "%<!here>%", "%<!channel>%", "%<!everyone>%"}
	for _, g := range w.myGroups {
		likes = append(likes, "%<!subteam^"+g+">%")
	}
	conds := make([]string, len(likes))
	args := []any{channelID, lastRead}
	for i, l := range likes {
		conds[i] = "text LIKE ?"
		args = append(args, l)
	}
	q := "SELECT count(*) FROM messages WHERE channel_id=? AND ts>? AND is_deleted=0 AND (" + strings.Join(conds, " OR ") + ")"
	var n int
	d.cacheDB.QueryRowContext(d.ctx, q, args...).Scan(&n)
	return n
}

// channelMention computes the priority flag for a channel given its unread state.
func (d *daemon) channelMention(w *workspace, channelID, kind, lastRead string, unread int) bool {
	if unread == 0 {
		return false
	}
	if kind == "dm" {
		return true
	}
	return d.unreadMentionCount(w, channelID, lastRead) > 0
}

// skinTones maps Slack's "::skin-tone-N" reaction suffix to its Unicode modifier.
var skinTones = map[string]string{
	"skin-tone-2": "\U0001F3FB", "skin-tone-3": "\U0001F3FC", "skin-tone-4": "\U0001F3FD",
	"skin-tone-5": "\U0001F3FE", "skin-tone-6": "\U0001F3FF",
}

// emojiGlyph resolves a Slack reaction name to its display glyph: standard emoji via
// the codemap, "<base>::skin-tone-N" as base glyph + tone modifier, custom emoji left
// as :name: for the client to render as an image.
func emojiGlyph(name string) string {
	if u, ok := emojiMap[":"+name+":"]; ok {
		return u
	}
	if i := strings.Index(name, "::"); i > 0 {
		if bg, ok := emojiMap[":"+name[:i]+":"]; ok {
			if tone, ok := skinTones[name[i+2:]]; ok {
				return bg + tone
			}
			return bg
		}
	}
	return ":" + name + ":"
}

func (d *daemon) reactionsJSONFor(w *workspace, channelID, ts string) string {
	rows, err := d.cacheDB.QueryContext(d.ctx,
		`SELECT emoji, count, COALESCE(user_ids,'') FROM reactions WHERE channel_id=? AND message_ts=?`, channelID, ts)
	if err != nil {
		return "[]"
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var name, userIDs string
		var n int
		if rows.Scan(&name, &n, &userIDs) != nil {
			continue
		}
		// display glyph: standard → unicode (incl. skin tone), custom → :name: (img)
		e := emojiGlyph(name)
		// `mine` drives the toggle: reacting again with it removes it. `users`
		// is the resolved reactor names (self marked "(you)") for the react picker.
		// Slack truncates user_ids in history, so len(users) can be < n.
		mine := false
		users := []string{}
		if userIDs != "" {
			var ids []string
			if json.Unmarshal([]byte(userIDs), &ids) == nil {
				for _, u := range ids {
					nm := w.users[u]
					if nm == "" {
						nm = "someone"
					}
					if u == w.selfID {
						mine = true
						nm += " (you)"
					}
					users = append(users, nm)
				}
			}
		}
		out = append(out, map[string]any{"e": e, "n": n, "name": name, "mine": mine, "users": users})
	}
	b, _ := json.Marshal(out)
	return string(b)
}

// sendRecent serves a channel's current top-level history straight from cache.db
// (rich), replacing whatever the client had. Called on channel open — there is
// no static snapshot, so this is the authoritative initial load.
func (d *daemon) sendRecent(c net.Conn, w *workspace, channelID string) {
	// Backfill from the live API first: the websocket is unreliable, so a
	// channel's messages (and current reactions/counts) may be missing or stale
	// in the cache — otherwise a busy channel like #random renders blank.
	bctx, cancel := context.WithTimeout(d.ctx, 10*time.Second)
	if msgs, herr := w.client.GetHistory(bctx, channelID, 50, ""); herr == nil {
		for _, m := range msgs {
			d.persistMessage(w, channelID, m)
		}
	} else {
		log.Printf("recent backfill %s: %v", channelID, herr)
	}
	cancel()

	rows, err := d.cacheDB.QueryContext(d.ctx, `
		SELECT ts, user_id, text, reply_count, COALESCE(raw_json,'')
		FROM messages
		WHERE channel_id=? AND is_deleted=0
		      AND (text<>'' OR raw_json LIKE '%"files"%' OR raw_json LIKE '%"blocks"%' OR raw_json LIKE '%"attachments"%')
		      AND (thread_ts='' OR thread_ts=ts OR subtype='thread_broadcast')
		ORDER BY ts DESC LIMIT 70`, channelID)
	if err != nil {
		log.Printf("recent %s: %v", channelID, err)
		return
	}
	type row struct {
		ts, uid, text, raw string
		rc                 int
	}
	var rs []row
	for rows.Next() {
		var r row
		if rows.Scan(&r.ts, &r.uid, &r.text, &r.rc, &r.raw) == nil {
			rs = append(rs, r)
		}
	}
	rows.Close()
	ids := make([]string, len(rs))
	for i := range rs {
		ids[i] = rs[i].uid
	}
	d.resolveUnknownUsers(w, ids)
	// Build messages concurrently — msgFromRaw fetches thumbnails (slow part);
	// doing them in parallel turns ~N×latency into ~latency so an image-heavy
	// channel paints fast instead of blanking while files download serially.
	n := len(rs)
	out := make([]map[string]any, n)
	sem := make(chan struct{}, 12)
	var wg sync.WaitGroup
	for k := 0; k < n; k++ {
		wg.Add(1)
		go func(pos int, uid, ts, text, raw string, rc int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			out[pos] = d.msgFromRaw(w, channelID, uid, ts, text, rc, raw)
		}(n-1-k, rs[k].uid, rs[k].ts, rs[k].text, rs[k].raw, rs[k].rc) // DESC→chronological
	}
	wg.Wait()
	// Stream in small batches: one ~55KB line for a 70-message channel exceeds
	// the client Socket's parse buffer and silently truncates (channel renders
	// blank). Chunks of 20 keep each line well under that. reset clears the
	// view on the first chunk; final triggers the read-watermark update.
	const chunk = 20
	if len(out) == 0 {
		d.writeConn(c, map[string]any{"type": "recent", "workspace": w.teamID, "channel": channelID,
			"msgs": []map[string]any{}, "reset": true, "final": true})
		return
	}
	for i := 0; i < len(out); i += chunk {
		end := i + chunk
		if end > len(out) {
			end = len(out)
		}
		payload := map[string]any{"type": "recent", "workspace": w.teamID, "channel": channelID, "msgs": out[i:end]}
		if i == 0 {
			payload["reset"] = true
		}
		if end == len(out) {
			payload["final"] = true
		}
		d.writeConn(c, payload)
	}
}

// sendChannels pushes the workspace list, then the full channel list (every
// workspace, each entry tagged with its workspace) plus followed threads — the
// bootstrap a freshly connected client needs.
func (d *daemon) sendChannels(c net.Conn) {
	type wsEntry struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	var wsList []wsEntry
	for _, w := range d.wsList {
		wsList = append(wsList, wsEntry{w.teamID, w.teamName})
	}
	d.writeConn(c, map[string]any{"type": "workspaces", "workspaces": wsList})

	// Per-workspace user directory for @-mention autocomplete (id + display name).
	usersByWS := map[string][]map[string]string{}
	for _, w := range d.wsList {
		us := make([]map[string]string, 0, len(w.users))
		for id, name := range w.users {
			us = append(us, map[string]string{"id": id, "name": name})
		}
		usersByWS[w.teamID] = us
	}
	d.writeConn(c, map[string]any{"type": "users", "users": usersByWS})

	type entry struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		Kind      string `json:"kind"`
		Topic     string `json:"topic"`
		Unread    int    `json:"unread"`
		Mention   bool   `json:"mention"`
		Avatar    string `json:"avatar"`
		Workspace string `json:"workspace"`
		last      string
	}
	var entries []entry
	var subs []map[string]any
	for _, w := range d.wsList {
		for id, name := range w.chans {
			kind := w.chanKind[id]
			var last, lr sql.NullString
			d.cacheDB.QueryRowContext(d.ctx,
				`SELECT (SELECT MAX(ts) FROM messages m WHERE m.channel_id=?),
				        (SELECT last_read_ts FROM channels WHERE id=?)`, id, id).Scan(&last, &lr)
			lastV, lrV := last.String, lr.String
			// DMs: only ones actually "open" (a read watermark or synced messages);
			// slk hides the long tail of never-opened DMs.
			if kind == "dm" && !(lrV != "" && lrV != "0") && lastV == "" {
				continue
			}
			unread := 0
			base := lrV
			// No read watermark (channel never synced by GetUnreadCounts and never
			// opened here) → treat it as read up to the latest message. Falling back
			// to "0" counted the entire cached history as unread, which surfaced read
			// chats (and the Slackbot DM) as permanently unread.
			if base == "" || base == "0" {
				base = lastV
			}
			if lastV != "" && base != "" {
				d.cacheDB.QueryRowContext(d.ctx, `SELECT count(*) FROM messages
					WHERE channel_id=? AND ts>? AND is_deleted=0 AND text<>''
					      AND (thread_ts='' OR thread_ts=ts)`, id, base).Scan(&unread)
				if unread > 99 {
					unread = 99
				}
			}
			topic := stripMentionMarks(d.render(w, w.topics[id]))
			if len(topic) > 80 {
				topic = topic[:80]
			}
			avatar := ""
			if u := w.dmUser[id]; u != "" {
				avatar = d.avatarPath(u)
			}
			mention := d.channelMention(w, id, kind, base, unread)
			entries = append(entries, entry{id, name, kind, topic, unread, mention, avatar, w.teamID, lastV})
		}
		subs = append(subs, d.buildSubThreads(w)...)
	}
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].last > entries[j].last })

	// Threads come from the cache, which the reconnect backfill keeps current
	// against the live API (see backfill.go) and re-pushes via refreshChannels.
	d.writeConn(c, map[string]any{"type": "channels", "channels": entries, "subThreads": subs})

	// A notification was clicked while no window was open — open that target now
	// (after the channel list, so the client can resolve it).
	d.focusMu.Lock()
	po := d.pendingOpen
	d.pendingOpen = nil
	d.focusMu.Unlock()
	if po != nil {
		d.writeConn(c, po)
	}
}

func (d *daemon) writeConn(c net.Conn, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	b = append(b, '\n')
	d.mu.Lock()
	c.Write(b)
	d.mu.Unlock()
}

// sendBrowse returns all public channels in the workspace (id, name, whether
// already joined) for a browse picker.
func (d *daemon) sendBrowse(c net.Conn, w *workspace) {
	cs, err := w.client.GetAllPublicChannels(d.ctx)
	if err != nil {
		log.Printf("browse: %v", err)
		return
	}
	type be struct {
		ID     string `json:"id"`
		Name   string `json:"name"`
		Member bool   `json:"member"`
	}
	out := []be{}
	for _, ch := range cs {
		if ch.Name == "" {
			continue
		}
		out = append(out, be{ch.ID, cleanName(ch.Name), w.chans[ch.ID] != ""})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	d.writeConn(c, map[string]any{"type": "browse", "workspace": w.teamID, "channels": out})
}

// joinChannel joins a public channel and makes it appear in the sidebar. Channel
// maps are rebuilt copy-on-write (never mutated in place) so the poll/ws/read
// goroutines reading them can't hit a concurrent-map panic.
func (d *daemon) joinChannel(w *workspace, channelID, name string) {
	if err := w.client.JoinChannel(d.ctx, channelID); err != nil {
		log.Printf("join: %v", err)
		return
	}
	nc := make(map[string]string, len(w.chans)+1)
	for k, v := range w.chans {
		nc[k] = v
	}
	nc[channelID] = cleanName(name)
	nk := make(map[string]string, len(w.chanKind)+1)
	for k, v := range w.chanKind {
		nk[k] = v
	}
	nk[channelID] = "channel"
	ni := make(map[string]*workspace, len(d.idIndex)+1)
	for k, v := range d.idIndex {
		ni[k] = v
	}
	ni[channelID] = w
	w.chans, w.chanKind, d.idIndex = nc, nk, ni
	// refresh every client's sidebar, then open the joined channel
	d.mu.Lock()
	conns := make([]net.Conn, 0, len(d.conns))
	for cc := range d.conns {
		conns = append(conns, cc)
	}
	d.mu.Unlock()
	for _, cc := range conns {
		d.sendChannels(cc)
	}
	d.broadcast(map[string]any{"type": "open", "workspace": w.teamID, "channel": channelID, "thread": ""})
}

// registerChannel adds a channel the user was added to remotely (channel_joined,
// group_joined, or a newly opened DM) to the workspace maps. Like joinChannel it
// rebuilds the maps copy-on-write so the poll/ws/read goroutines never hit a
// concurrent-map panic; unlike joinChannel it makes no join API call and doesn't
// steal focus — the channel just appears in the sidebar. No-op if already known.
func (d *daemon) registerChannel(w *workspace, ch slack.Channel) {
	id := ch.ID
	if id == "" || w.chans[id] != "" {
		return
	}
	kind, name := "channel", cleanName(ch.Name)
	switch {
	case ch.IsIM:
		kind = "dm"
		if name = w.users[ch.User]; name == "" {
			name = ch.User
		}
	case ch.IsMpIM:
		kind = "dm"
	}
	if name == "" {
		return
	}
	nc := make(map[string]string, len(w.chans)+1)
	for k, v := range w.chans {
		nc[k] = v
	}
	nc[id] = name
	nk := make(map[string]string, len(w.chanKind)+1)
	for k, v := range w.chanKind {
		nk[k] = v
	}
	nk[id] = kind
	nt := make(map[string]string, len(w.topics)+1)
	for k, v := range w.topics {
		nt[k] = v
	}
	nt[id] = ch.Topic.Value
	nd := make(map[string]string, len(w.dmUser)+1)
	for k, v := range w.dmUser {
		nd[k] = v
	}
	if ch.IsIM {
		nd[id] = ch.User
	}
	ni := make(map[string]*workspace, len(d.idIndex)+1)
	for k, v := range d.idIndex {
		ni[k] = v
	}
	ni[id] = w
	w.chans, w.chanKind, w.topics, w.dmUser, d.idIndex = nc, nk, nt, nd, ni
	log.Printf("[%s] registered channel %s (%s) from live event", w.teamName, id, name)
	d.mu.Lock()
	conns := make([]net.Conn, 0, len(d.conns))
	for cc := range d.conns {
		conns = append(conns, cc)
	}
	d.mu.Unlock()
	for _, cc := range conns {
		d.sendChannels(cc)
	}
}

// buildSubThreads returns the followed-threads list from the cache. The
// reconnect backfill (backfill.go) keeps the underlying subscriptions current
// against the live API, so this stays authoritative without a per-call fetch.
func (d *daemon) buildSubThreads(w *workspace) []map[string]any {
	rows, err := d.cacheDB.QueryContext(d.ctx,
		`SELECT channel_id, thread_ts, COALESCE(last_read,'0') FROM thread_subscriptions
		 WHERE workspace_id=? AND active=1`, w.teamID)
	if err != nil {
		return nil
	}
	type sub struct{ cid, tts, lr string }
	var subs []sub
	for rows.Next() {
		var s sub
		if rows.Scan(&s.cid, &s.tts, &s.lr) == nil {
			subs = append(subs, s)
		}
	}
	rows.Close()

	var out []map[string]any
	for _, s := range subs {
		cname := w.chans[s.cid]
		if cname == "" {
			continue
		}
		var puid, ptext, praw string
		var prc int
		err := d.cacheDB.QueryRowContext(d.ctx,
			`SELECT user_id, text, reply_count, COALESCE(raw_json,'') FROM messages
			 WHERE channel_id=? AND ts=? AND is_deleted=0`, s.cid, s.tts).Scan(&puid, &ptext, &prc, &praw)
		if err != nil {
			continue
		}
		var unread int
		d.cacheDB.QueryRowContext(d.ctx, `SELECT count(*) FROM messages
			WHERE channel_id=? AND thread_ts=? AND ts>? AND ts<>thread_ts
			      AND is_deleted=0 AND text<>''`, s.cid, s.tts, s.lr).Scan(&unread)
		if unread > 99 {
			unread = 99
		}
		var lastTS sql.NullString
		d.cacheDB.QueryRowContext(d.ctx, `SELECT MAX(ts) FROM messages WHERE channel_id=? AND thread_ts=?`,
			s.cid, s.tts).Scan(&lastTS)
		last := lastTS.String
		if last == "" {
			last = s.tts
		}
		pm := d.msgFromRaw(w, s.cid, puid, s.tts, ptext, prc, praw)
		lsec := last
		if i := strings.IndexByte(last, '.'); i >= 0 {
			lsec = last[:i]
		}
		ls, _ := strconv.ParseInt(lsec, 10, 64)
		preview := stripMentionMarks(strings.Join(strings.Fields(d.render(w, ptext)), " "))
		if len(preview) > 140 {
			preview = preview[:140]
		}
		out = append(out, map[string]any{
			"channel": s.cid, "channelName": cname, "workspace": w.teamID,
			"ts": s.tts, "title": pm["author"], "preview": preview,
			"avatar": pm["avatar"], "color": pm["color"], "initials": pm["initials"],
			"replyCount": prc, "lastTime": time.Unix(ls, 0).Format("Jan 02, 15:04"),
			"unread": unread, "last": last, "parent": pm,
		})
	}
	// Most-recent activity first (matches the official client's Threads view),
	// so today's/yesterday's threads sit at the top instead of being buried.
	sort.SliceStable(out, func(i, j int) bool {
		return out[i]["last"].(string) > out[j]["last"].(string)
	})
	return out
}
