// slqs — the backend daemon for the native (QML/QuickShell) Slack client.
// Opens its own Slack websocket per workspace, persists live events to a SQLite
// cache, and streams newline-delimited JSON over a Unix socket to the QML UI.
// Replaces the slk TUI entirely (the name is slk-on-QuickShell). Reuses slk's
// internal/slack + internal/cache + internal/notify packages.
//
//	go run ./cmd/slqs
//	socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/slqs.sock   # to eyeball the stream
package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/slack-go/slack"
	_ "modernc.org/sqlite"
	"slqs/internal/cache"
	"slqs/internal/emoji"
	"slqs/internal/notify"
	slackclient "slqs/internal/slack"
	"slqs/internal/slackhttp"
)

var palette = []string{"#FF570D", "#97B5A6", "#7DD3FC", "#8A92A7", "#ff8a31", "#CCD5E4", "#FF7B72", "#8A9AA6"}

// fileHTTP downloads thumbnails/avatars; a timeout keeps one stalled file from
// holding a concurrency slot (sendRecent fetches images in parallel).
var fileHTTP = &http.Client{Timeout: 20 * time.Second, Transport: slackhttp.HardenedTransport()}

// gitRev is the build's git commit, injected via -ldflags "-X main.gitRev=...".
// Empty on a plain `go build` (dev), which disables the update check.
var gitRev string

func shortRev(s string) string {
	if len(s) >= 7 {
		return s[:7]
	}
	return s
}

// Full standard shortcode→unicode table from slk's iamcal-derived map.
var emojiMap = emoji.CodeMap()

var (
	reToken     = regexp.MustCompile(`<([^>]+)>`)
	reEmoji     = regexp.MustCompile(`:([a-z0-9_+\-]+):`)
	reBold      = regexp.MustCompile(`(^|[\s(])\*([^\s*][^*\n]*?)\*([\s).,!?;:]|$)`)
	reStrike    = regexp.MustCompile(`~([^~\n]+)~`)
	reMpdmN     = regexp.MustCompile(`-\d+$`)
	reLink      = regexp.MustCompile(`<(https?://[^|>\s]+)`)
	reChanRef   = regexp.MustCompile(`<#([A-Z0-9]+)`) // first channel mention id, for `o` to open
	reCodeBlock = regexp.MustCompile("(?s)```.*?```")
)

// firstLink returns the primary URL in a message (kept so the client's `o`
// can open it — render() drops the URL when keeping a link's label).
func firstLink(text string) string {
	if m := reLink.FindStringSubmatch(text); m != nil {
		return html.UnescapeString(m[1])
	}
	return ""
}

// firstChanRef returns the channel id of the first <#CID|name> mention in text,
// so the client can open that channel (e.g. pressing `o` on the message).
func firstChanRef(text string) string {
	if m := reChanRef.FindStringSubmatch(text); m != nil {
		return m[1]
	}
	return ""
}

func xdgData() string {
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return filepath.Join(d, "slqs")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "slqs")
}

func socketPath() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "slqs.sock")
	}
	return "/tmp/slqs.sock"
}

// prefetchAvatars downloads each user's avatar into slk's image cache as
// avatar-<id>.<ext> (skipping ones already there), so the client renders from
// local files instead of flooding avatars.slack-edge.com with concurrent
// requests (Qt caps at 6 per host, so remote loads stall).
func prefetchAvatars(users []slack.User) {
	dir := filepath.Join(os.Getenv("HOME"), ".cache", "slqs", "images")
	os.MkdirAll(dir, 0700)
	// Write crisp avatars to avatar-<id>-hi.<ext>; skip if already present.
	existing := map[string]bool{}
	if ents, err := os.ReadDir(dir); err == nil {
		for _, e := range ents {
			if strings.HasSuffix(strings.SplitN(e.Name(), ".", 2)[0], "-hi") {
				name := strings.TrimSuffix(strings.SplitN(e.Name(), ".", 2)[0], "-hi")
				existing[strings.TrimPrefix(name, "avatar-")] = true
			}
		}
	}
	sem := make(chan struct{}, 6) // respect the per-host connection cap
	var wg sync.WaitGroup
	n := 0
	for _, u := range users {
		if existing[u.ID] {
			continue
		}
		url := u.Profile.Image512
		if url == "" {
			url = u.Profile.ImageOriginal
		}
		if url == "" {
			url = u.Profile.Image192
		}
		if url == "" || !strings.HasPrefix(url, "http") {
			continue
		}
		ext := "png"
		if i := strings.LastIndexByte(url, '.'); i >= 0 && len(url)-i <= 5 {
			ext = strings.ToLower(url[i+1:])
		}
		wg.Add(1)
		n++
		go func(id, url, ext string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			resp, err := http.Get(url)
			if err != nil {
				return
			}
			defer resp.Body.Close()
			if resp.StatusCode != 200 {
				return
			}
			b, err := io.ReadAll(resp.Body)
			if err != nil {
				return
			}
			os.WriteFile(filepath.Join(dir, "avatar-"+id+"-hi."+ext), b, 0644)
		}(u.ID, url, ext)
	}
	wg.Wait()
	log.Printf("avatar prefetch done (%d fetched)", n)
}

// cacheAvatar downloads one resolved user's avatar into the same cache
// prefetchAvatars uses and registers it in d.avatars, so users missing from the
// startup prefetch (external / Slack-Connect) show a photo instead of initials.
// Best-effort; the on-disk file also survives a later scanAvatars re-scan.
func (d *daemon) cacheAvatar(u slack.User) {
	id := u.ID
	if id == "" {
		return
	}
	d.avMu.RLock()
	have := d.avatars[id] != ""
	d.avMu.RUnlock()
	if have {
		return
	}
	url := u.Profile.Image512
	if url == "" {
		url = u.Profile.ImageOriginal
	}
	if url == "" {
		url = u.Profile.Image192
	}
	if url == "" || !strings.HasPrefix(url, "http") {
		return
	}
	ext := "png"
	if i := strings.LastIndexByte(url, '.'); i >= 0 && len(url)-i <= 5 {
		ext = strings.ToLower(url[i+1:])
	}
	resp, err := http.Get(url)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return
	}
	dir := filepath.Join(os.Getenv("HOME"), ".cache", "slqs", "images")
	path := filepath.Join(dir, "avatar-"+id+"-hi."+ext)
	// tmp+rename: a reader mid-write sees the old file or none, never a torso
	tmpA := path + ".tmp"
	if os.WriteFile(tmpA, b, 0644) != nil || os.Rename(tmpA, path) != nil {
		return
	}
	d.avMu.Lock()
	d.avatars[id] = "file://" + path
	d.avMu.Unlock()
}

// nameFor resolves a user's name per the workspace's preference: "display"
// prefers their chosen Slack display name, anything else prefers the full real
// name (consistent "David Karlsson" rather than a mix of casual handles).
func nameFor(u slack.User, pref string) string {
	real := u.Profile.RealName
	if real == "" {
		real = u.RealName
	}
	disp := u.Profile.DisplayName
	if pref == "display" {
		if disp != "" {
			return disp
		}
		if real != "" {
			return real
		}
	} else {
		if real != "" {
			return real
		}
		if disp != "" {
			return disp
		}
	}
	return u.Name
}

func cleanName(name string) string {
	if strings.HasPrefix(name, "mpdm-") {
		s := reMpdmN.ReplaceAllString(name[5:], "")
		var parts []string
		for _, p := range strings.Split(s, "--") {
			if p != "" {
				parts = append(parts, p)
			}
		}
		if len(parts) > 0 {
			return strings.Join(parts, ", ")
		}
	}
	return name
}

func initials(name string) string {
	parts := strings.FieldsFunc(name, func(r rune) bool { return r == ' ' || r == '.' || r == '_' || r == '-' })
	if len(parts) == 0 {
		return "?"
	}
	if len(parts) == 1 {
		r := []rune(strings.ToUpper(parts[0]))
		if len(r) > 2 {
			r = r[:2]
		}
		return string(r)
	}
	return strings.ToUpper(string([]rune(parts[0])[:1]) + string([]rune(parts[1])[:1]))
}

func colorFor(id string) string {
	sum := 0
	for _, r := range id {
		sum += int(r)
	}
	return palette[sum%len(palette)]
}

// workspace holds the per-Slack-team state. cache.db namespaces everything by
// workspace_id; channel IDs are globally unique across teams, so the wire
// protocol keys channels by ID (no name collisions between workspaces).
type workspace struct {
	teamID   string
	teamName string
	token    string
	cookie   string
	selfID   string
	client   *slackclient.Client
	users    map[string]string // user id -> display name
	chans    map[string]string // channel id -> display name
	chanKind map[string]string // channel id -> "channel"|"dm"
	topics   map[string]string // channel id -> topic
	dmUser   map[string]string // DM channel id -> other user id (for avatar)
	subteams map[string]string // user-group id -> @handle (resolve <!subteam^ID>)
	myGroups []string          // user-group ids self belongs to (for @-group mentions)
	namePref string            // "real" (default) | "display" — how to resolve user names

	presMu   sync.Mutex
	presence map[string]string   // user id -> "active"|"away"
	presSubs map[string]struct{} // desired presence_sub set (Slack replaces the list wholesale)
	status   map[string]string   // user id -> status emoji (glyph, or ":name:" for custom)
}

type daemon struct {
	ctx context.Context

	wss     map[string]*workspace // teamID -> workspace
	wsList  []*workspace          // token order, for stable display
	idIndex map[string]*workspace // channel id -> owning workspace

	notifier    *notify.Notifier
	focusMu     sync.RWMutex
	activeCh    string         // channel id the user is viewing in the client
	activeWS    string         // teamID the user is viewing
	appActive   bool           // client window focused
	pendingOpen map[string]any // notification target to open on next client connect

	attachMu            sync.Mutex
	pendingAttach       map[string]string        // channel id -> staged file id, posted with next send
	pendingAttachThread map[string]string        // channel id -> thread ts the staged file belongs to ("" = channel)
	uploading           map[string]chan struct{} // channel id -> closed when an in-flight upload finishes

	avMu    sync.RWMutex
	avatars map[string]string // userID -> file:// path

	backfillMu   sync.Mutex
	lastBackfill map[string]time.Time // teamID -> last reconnect-backfill start

	threadsDirtyMu    sync.Mutex
	threadsDirtyTimer *time.Timer // debounced threads-list re-push on live activity

	cacheDB *sql.DB   // read-only handle for serving reads
	writeDB *cache.DB // read-write handle the websocket handler persists through

	mu    sync.Mutex
	conns map[net.Conn]struct{}

	userMiss map[string]bool // author IDs users.info couldn't resolve — don't refetch (guarded by mu)

	updateEvent map[string]any // latest updateAvailable event, replayed to new clients
	updMu       sync.Mutex
	updEtag     string    // GitHub ETag — conditional requests are free
	updLast     time.Time // last update check, for connect throttle

	presenceActive atomic.Bool // false while idle (swayidle) — gates the tickle heartbeat
}

// cacheFile downloads an authed Slack file (thumbnail) into the shared image
// cache and returns its file:// path, skipping the fetch if already present.
func (d *daemon) cacheFile(id, url, ext, token, cookie string) string {
	dir := filepath.Join(os.Getenv("HOME"), ".cache", "slqs", "files")
	os.MkdirAll(dir, 0755)
	dst := filepath.Join(dir, id+"."+ext)
	path := "file://" + dst
	if _, err := os.Stat(dst); err == nil {
		return path
	}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Cookie", "d="+cookie)
	resp, err := fileHTTP.Do(req)
	if err != nil || resp.StatusCode != 200 {
		if resp != nil {
			resp.Body.Close()
		}
		return ""
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return ""
	}
	tmpF := dst + ".tmp"
	if os.WriteFile(tmpF, b, 0644) != nil || os.Rename(tmpF, dst) != nil {
		return ""
	}
	return path
}

var imgSem = make(chan struct{}, 16) // global cap on concurrent image fetches

func filesCacheDir() string { return filepath.Join(os.Getenv("HOME"), ".cache", "slqs", "files") }

// imagesJSON builds the inline-image array WITHOUT blocking on downloads, so a
// channel paints instantly. Files not yet cached come back with "pending":true
// (the client shows a sized placeholder) and are fetched in the background;
// when a message's images finish, an "images" update is broadcast so the client
// swaps in the real thumbnails. channelID=="" disables the background refresh
// (used for the re-broadcast itself, so it doesn't loop).
func (d *daemon) imagesJSON(w *workspace, channelID, ts string, files []slack.File, attachments []slack.Attachment) string {
	dir := filesCacheDir()
	os.MkdirAll(dir, 0755)
	type task struct {
		dst, url string
		video    bool // url is a video → derive the poster via ffmpeg, not download
	}
	var pending []task
	out := []map[string]any{}
	add := func(id, src, ext, full, mtype string, ww, hh int) {
		if src == "" || id == "" {
			return
		}
		dst := filepath.Join(dir, id+"."+ext)
		ready := false
		if _, err := os.Stat(dst); err == nil {
			ready = true
		} else {
			pending = append(pending, task{dst, src, false})
		}
		// channelID=="" is the post-download re-broadcast: drop images whose file
		// still isn't there (download failed, e.g. an expired unfurl URL) so the
		// client clears the placeholder instead of showing an empty box forever.
		if channelID == "" && !ready {
			return
		}
		out = append(out, map[string]any{
			"path": "file://" + dst, "w": ww, "h": hh,
			"id": id, "full": full, "ext": ext, "type": mtype, "pending": !ready,
		})
	}
	for _, f := range files {
		if strings.HasPrefix(f.Mimetype, "video/") {
			// Video file: cache Slack's still poster (if any) for inline display.
			// The video URL rides as `full`, so `v` runs the same view flow as a
			// photo — slkd downloads it with auth, media-viewer.sh plays it in mpv.
			poster := f.Thumb720
			if poster == "" {
				poster = f.Thumb480
			}
			if poster == "" {
				poster = f.Thumb360
			}
			vext := f.Filetype
			if vext == "" {
				vext = "mp4"
			}
			vw, vh := f.Thumb360W, f.Thumb360H
			if vw == 0 {
				vw, vh = f.OriginalW, f.OriginalH
			}
			pdst := filepath.Join(dir, f.ID+"-poster.jpg")
			ppath, ready := "file://"+pdst, true
			if _, err := os.Stat(pdst); err != nil {
				ready = false
				if poster != "" {
					pending = append(pending, task{pdst, poster, false})
				} else {
					// Slack generated no still — derive one from the first frame.
					pending = append(pending, task{pdst, f.URLPrivate, true})
				}
			}
			// Unlike images, keep the video on the re-broadcast even if its poster
			// is still missing — the card stays playable without one.
			out = append(out, map[string]any{
				"path": ppath, "w": vw, "h": vh,
				"id": f.ID + "-vid", "full": f.URLPrivate, "ext": vext, "type": "video", "pending": !ready,
			})
			continue
		}
		if !strings.HasPrefix(f.Mimetype, "image/") {
			// documents/archives/etc: no inline render — emit a file chip
			// (name + permalink; the UI opens it in Slack via the browser)
			out = append(out, map[string]any{
				"path": "", "w": 0, "h": 0,
				"id": f.ID, "full": f.URLPrivate, "ext": f.Filetype,
				"type": "file", "name": f.Name, "size": f.Size,
				"link": f.Permalink, "pending": false,
			})
			continue
		}
		isGif := f.Mimetype == "image/gif"
		ext := f.Filetype
		if ext == "" {
			if isGif {
				ext = "gif"
			} else {
				ext = "jpg"
			}
		}
		// gif: the animated original (plays inline); else the largest still
		// thumbnail (720 is crisp at our inline cap on HiDPI).
		src := f.Thumb720
		if src == "" {
			src = f.Thumb480
		}
		if src == "" {
			src = f.Thumb360
		}
		if isGif || src == "" {
			src = f.URLPrivate
		}
		fw, fh := f.Thumb360W, f.Thumb360H
		if fw == 0 {
			fw, fh = f.OriginalW, f.OriginalH
		}
		mtype := "img"
		if isGif {
			mtype = "gif"
		}
		add(f.ID+"-hq", src, ext, f.URLPrivate, mtype, fw, fh)
	}
	for _, a := range attachments {
		url := a.ImageURL
		if url == "" {
			url = a.ThumbURL
		}
		if url == "" {
			continue
		}
		ext := "jpg"
		switch {
		case strings.Contains(strings.ToLower(url), ".png"):
			ext = "png"
		case strings.Contains(strings.ToLower(url), ".gif"):
			ext = "gif"
		}
		mtype := "img"
		if ext == "gif" {
			mtype = "gif"
		}
		// Cache key must be unique per image URL. Keying by URL *length* collided
		// every same-site link (YouTube thumbs are all the same length, etc.), so
		// they all reused the first download's file. Hash the URL instead.
		uh := fnv.New64a()
		uh.Write([]byte(url))
		add(fmt.Sprintf("unf-%016x", uh.Sum64()), url, ext, url, mtype, a.ImageWidth, a.ImageHeight)
	}
	if len(pending) > 0 && channelID != "" {
		go func(tasks []task) {
			run := func(t task) bool {
				imgSem <- struct{}{}
				defer func() { <-imgSem }()
				if t.video {
					return d.extractPoster(t.dst, t.url, w.token, w.cookie)
				}
				return d.downloadFile(t.dst, t.url, w.token, w.cookie)
			}
			var wg sync.WaitGroup
			failedCh := make(chan task, len(tasks))
			for _, t := range tasks {
				wg.Add(1)
				go func(t task) {
					defer wg.Done()
					if !run(t) {
						failedCh <- t
					}
				}(t)
			}
			wg.Wait()
			close(failedCh)
			var failed []task
			for t := range failedCh {
				failed = append(failed, t)
			}
			// Thumbnails for a just-uploaded video 404 until Slack generates
			// them — give transient failures two more passes before giving up.
			for attempt := 0; len(failed) > 0 && attempt < 2; attempt++ {
				time.Sleep(time.Duration(5+15*attempt) * time.Second)
				var still []task
				for _, t := range failed {
					if !run(t) {
						still = append(still, t)
					}
				}
				failed = still
			}
			d.broadcast(map[string]any{"type": "images", "workspace": w.teamID,
				"channel": channelID, "ts": ts, "imagesJson": d.imagesJSON(w, "", "", files, attachments)})
		}(pending)
	}
	b, _ := json.Marshal(out)
	return string(b)
}

// downloadFile fetches an authed Slack file to dst (no-op if already present).
// Reports success so the caller can retry transient failures (a just-uploaded
// video's thumbnail URL 404s until Slack finishes generating it).
func (d *daemon) downloadFile(dst, url, token, cookie string) bool {
	if _, err := os.Stat(dst); err == nil {
		return true
	}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return false
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Cookie", "d="+cookie)
	resp, err := fileHTTP.Do(req)
	if err != nil || resp.StatusCode != 200 {
		status := 0
		if resp != nil {
			status = resp.StatusCode
			resp.Body.Close()
		}
		log.Printf("download failed %s: status=%d err=%v", filepath.Base(dst), status, err)
		return false
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("download failed %s: %v", filepath.Base(dst), err)
		return false
	}
	// tmp+rename so the UI never reads a half-written image.
	tmp := dst + ".tmp"
	if os.WriteFile(tmp, b, 0644) != nil {
		os.Remove(tmp)
		return false
	}
	return os.Rename(tmp, dst) == nil
}

// extractPoster derives a JPEG poster from a video's first frame, for videos
// Slack never made a still for. ffmpeg streams the URL with the same auth as
// downloadFile, reading only enough to decode one frame.
func (d *daemon) extractPoster(dst, videoURL, token, cookie string) bool {
	if _, err := os.Stat(dst); err == nil {
		return true
	}
	hdr := fmt.Sprintf("Authorization: Bearer %s\r\nCookie: d=%s\r\n", token, cookie)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// Render to a tmp then rename: a timeout mid-write would otherwise leave a
	// truncated poster whose existence blocks regeneration forever.
	tmp := dst + ".tmp"
	cmd := exec.CommandContext(ctx, "ffmpeg", "-nostdin", "-y",
		"-headers", hdr, "-i", videoURL, "-frames:v", "1", "-q:v", "4", "-f", "image2", tmp)
	err := cmd.Run()
	if st, serr := os.Stat(tmp); err != nil || serr != nil || st.Size() == 0 {
		os.Remove(tmp)
		log.Printf("poster extract failed %s: %v", filepath.Base(dst), err)
		return false
	}
	return os.Rename(tmp, dst) == nil
}

func (d *daemon) avatarPath(uid string) string {
	d.avMu.RLock()
	defer d.avMu.RUnlock()
	return d.avatars[uid]
}

func (d *daemon) scanAvatars() {
	dir := filepath.Join(os.Getenv("HOME"), ".cache", "slqs", "images")
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	m := map[string]string{}
	for _, e := range ents {
		n := e.Name()
		if !strings.HasPrefix(n, "avatar-") {
			continue
		}
		stem := strings.SplitN(n[len("avatar-"):], ".", 2)[0]
		path := "file://" + filepath.Join(dir, n)
		if strings.HasSuffix(stem, "-hi") {
			m[strings.TrimSuffix(stem, "-hi")] = path // hi-res wins
		} else if _, ok := m[stem]; !ok {
			m[stem] = path
		}
	}
	d.avMu.Lock()
	d.avatars = m
	d.avMu.Unlock()
}

// Mention markers wrap resolved mentions so the client can style them. Private-
// use runes survive JSON + HTML-escaping; stripMentionMarks() removes them for
// plain-text contexts (notifications, topics, previews).
const (
	markMent = "\ue000" // start: a mention/#channel (styled by the client)
	markSelf = "\ue001" // start: a mention of self / @here|channel|everyone (highlighted)
	markEnd  = "\ue002" // end of either
)

func wrapMent(self bool, s string) string {
	if self {
		return markSelf + s + markEnd
	}
	return markMent + s + markEnd
}

var mentMarkStripper = strings.NewReplacer(markMent, "", markSelf, "", markEnd, "")

func stripMentionMarks(s string) string { return mentMarkStripper.Replace(s) }

func (d *daemon) render(w *workspace, text string) string {
	var codeBlocks []string
	text = reCodeBlock.ReplaceAllStringFunc(text, func(m string) string {
		codeBlocks = append(codeBlocks, m)
		return "" + strconv.Itoa(len(codeBlocks)-1) + ""
	})
	text = reToken.ReplaceAllStringFunc(text, func(m string) string {
		s := m[1 : len(m)-1]
		switch {
		case strings.HasPrefix(s, "@"):
			body := strings.SplitN(s[1:], "|", 2)
			name := "someone"
			if len(body) > 1 {
				name = body[1]
			} else if n, ok := w.users[body[0]]; ok {
				name = n
			}
			return wrapMent(body[0] == w.selfID, "@"+name)
		case strings.HasPrefix(s, "#"):
			body := strings.SplitN(s[1:], "|", 2)
			name := "channel"
			if len(body) > 1 {
				name = body[1]
			} else if n, ok := w.chans[body[0]]; ok {
				name = n
			}
			return wrapMent(false, "#"+name)
		case strings.HasPrefix(s, "!"):
			body := strings.SplitN(s[1:], "|", 2)
			if len(body) > 1 {
				return wrapMent(true, "@"+body[1])
			}
			name := body[0]
			// <!subteam^ID> with no inline label → resolve to the group's @handle.
			if rest, ok := strings.CutPrefix(name, "subteam^"); ok {
				self := false
				for _, g := range w.myGroups {
					if g == rest {
						self = true
						break
					}
				}
				if h, ok := w.subteams[rest]; ok {
					return wrapMent(self, "@"+h)
				}
				return wrapMent(self, "@group")
			}
			return wrapMent(true, "@"+name) // here / channel / everyone
		default:
			body := strings.SplitN(s, "|", 2)
			if len(body) > 1 {
				return body[1]
			}
			return body[0]
		}
	})
	text = html.UnescapeString(text)
	text = reEmoji.ReplaceAllStringFunc(text, func(m string) string {
		if e, ok := emojiMap[m]; ok { // CodeMap keys are colon-wrapped (":+1:")
			return e
		}
		return m // custom emoji left as :name: for the client to render as <img>
	})
	text = reBold.ReplaceAllString(text, "${1}**${2}**${3}")
	text = reStrike.ReplaceAllString(text, "~~$1~~")
	for i, c := range codeBlocks {
		text = strings.Replace(text, ""+strconv.Itoa(i)+"", c, 1)
	}
	return strings.TrimSpace(text)
}

func (d *daemon) broadcast(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	b = append(b, '\n')
	d.mu.Lock()
	defer d.mu.Unlock()
	for c := range d.conns {
		if _, err := c.Write(b); err != nil {
			c.Close()
			delete(d.conns, c)
		}
	}
}

// formatMsg shapes one message the way Backend.qml expects. Grouping is left
// to the QML side (it has the full ordered list); ts is carried so the client
// can request older history before it. Used by the API-backed history/replies
// paths; the cache path uses msgFromRaw (richer: reactions, block text).
// msgBody resolves a live slack.Message's display text the same way msgFromRaw
// does for cached rows: Block Kit text (bot/Slackbot messages put their content
// there, not in `text`) wins, then plain text, then attachment text. Without
// this, formatMsg-rendered views (threads, history, jump) showed bot messages
// as empty rows.
func (d *daemon) msgBody(m slack.Message) string {
	body := m.Text
	raw, _ := json.Marshal(m)
	if bt := textFromBlocks(string(raw)); bt != "" {
		body = bt
	}
	if body == "" {
		body = attachmentText(m.Attachments)
	}
	return body
}

// displayText is the one answer for "what does this message say": Block Kit
// content over the flat fallback text, shared Slack messages appended as
// quotes (a smiley next to a share must not hide it), and attachment
// content (incl. unfurl-only URLs like Linear updates) when the message
// would otherwise be blank — threads dropped those entirely.
func displayText(m slack.Message) string {
	body := m.Text
	if len(m.Blocks.BlockSet) > 0 {
		if raw, err := json.Marshal(m); err == nil {
			if bt := textFromBlocks(string(raw)); bt != "" {
				body = bt
			}
		}
	}
	if shares := shareQuotes(m.Attachments); shares != "" {
		if body != "" {
			body += "\n"
		}
		body += shares
	} else if body == "" {
		body = attachmentText(m.Attachments)
	}
	return body
}

// authorOf is the effective identity for avatar/color lookup: bot messages
// carry an empty User but a BotID, and avatars are cached under the bot id
// (matching how the cache path normalizes it). Without this, live-fetched
// thread/history/jump rows for bots lost their avatar and fell back to initials.
func authorOf(m slack.Message) string {
	if m.User != "" {
		return m.User
	}
	return m.BotID
}

func (d *daemon) formatMsg(w *workspace, channelID, userID, ts, text, username string, files []slack.File, attachments []slack.Attachment, subType, threadTS string) map[string]any {
	author := w.users[userID]
	if author == "" {
		if username != "" {
			author = username
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
		"time":          time.Unix(s, 0).Format("15:04"), // local tz
		"text":          d.render(w, text),
		"grouped":       false,
		"reactionsJson": d.reactionsJSONFor(w, channelID, ts),
		"imagesJson":    d.imagesJSON(w, channelID, ts, files, attachments),
		"link":          firstLink(text),
		"channelRef":    firstChanRef(text),
		"ts":            ts,
		"reply_count":   0,
		"mine":          userID != "" && userID == w.selfID,
		"subtype":       subType,
		"thread_ts":     threadTS,
	}
}

// checkUpdate does one update check against the repo's main SHA. ETag-conditional
// (a 304 is free against GitHub's rate limit). Detect-only; the host applies via
// flake bump + rebuild. Safe to call concurrently (accept loop + poll goroutine).
func (d *daemon) checkUpdate(ctx context.Context) {
	if gitRev == "" {
		return
	}
	d.updMu.Lock()
	etag := d.updEtag
	d.updLast = time.Now()
	d.updMu.Unlock()
	req, err := http.NewRequestWithContext(ctx, "GET", "https://api.github.com/repos/daphen/slqs/commits/main", nil)
	if err != nil {
		return
	}
	req.Header.Set("User-Agent", "slqs")
	req.Header.Set("Accept", "application/vnd.github.sha")
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	resp, err := fileHTTP.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return // 304 unchanged (ETag hit), or transient error
	}
	d.updMu.Lock()
	d.updEtag = resp.Header.Get("ETag")
	d.updMu.Unlock()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 64))
	latest := strings.TrimSpace(string(b))
	if latest != "" && latest != gitRev {
		ev := map[string]any{"type": "updateAvailable",
			"current": shortRev(gitRev), "latest": shortRev(latest)}
		d.mu.Lock()
		d.updateEvent = ev
		d.mu.Unlock()
		d.broadcast(ev)
	}
}

// pollCache watches slk's SQLite cache for new messages instead of opening a
// second Slack websocket (two live sockets on one token contend — slk, the
// user's primary, wins and slqs's stream starves). slk writes every received
// message to cache.db, so polling it keeps us perfectly in sync with slk with
// zero extra Slack connections.
func (d *daemon) pollWorkspace(ctx context.Context, w *workspace) {
	db := d.cacheDB
	workspaceID := w.teamID

	// Start from the current max ts — don't replay history (clients load it
	// fresh from cache.db on channel open). SLKD_SINCE overrides for testing.
	var lastTS string
	db.QueryRow(`SELECT COALESCE(MAX(ts),'0') FROM messages WHERE workspace_id=?`, workspaceID).Scan(&lastTS)
	if s := os.Getenv("SLKD_SINCE"); s != "" {
		lastTS = s
	}
	log.Printf("[%s] cache poll: watching from ts=%s (self=%s)", w.teamName, lastTS, w.selfID)

	// Track each channel's last_read_ts so we can detect reads made in slk (or
	// any other client) and push unread updates — keeps our badges in sync
	// without us being the one who marked the channel read. Seeded silently.
	lastRead := map[string]string{}
	seedRows, _ := db.QueryContext(ctx, `SELECT id, last_read_ts FROM channels WHERE workspace_id=?`, workspaceID)
	if seedRows != nil {
		for seedRows.Next() {
			var id, lr string
			if seedRows.Scan(&id, &lr) == nil {
				lastRead[id] = lr
			}
		}
		seedRows.Close()
	}
	threadRead := map[string]string{}
	tseed, _ := db.QueryContext(ctx, `SELECT channel_id, thread_ts, last_read FROM thread_subscriptions WHERE workspace_id=? AND active=1`, workspaceID)
	if tseed != nil {
		for tseed.Next() {
			var cid, tts, lr string
			if tseed.Scan(&cid, &tts, &lr) == nil {
				threadRead[cid+"|"+tts] = lr
			}
		}
		tseed.Close()
	}

	tick := time.NewTicker(400 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		rows, err := db.QueryContext(ctx, `
			SELECT ts, channel_id, user_id, text, thread_ts, reply_count, COALESCE(raw_json,'')
			FROM messages
			WHERE workspace_id=? AND ts>? AND is_deleted=0
			      AND (text<>'' OR raw_json LIKE '%"files"%' OR raw_json LIKE '%"blocks"%' OR raw_json LIKE '%"attachments"%')
			ORDER BY ts ASC LIMIT 200`, workspaceID, lastTS)
		if err != nil {
			continue
		}
		for rows.Next() {
			var ts, chID, uID, text, threadTS, raw string
			var rc int
			if rows.Scan(&ts, &chID, &uID, &text, &threadTS, &rc, &raw) != nil {
				continue
			}
			if ts > lastTS {
				lastTS = ts
			}
			if w.chans[chID] == "" {
				continue // not a channel this workspace knows
			}
			d.resolveUnknownUsers(w, []string{uID})
			d.broadcast(map[string]any{
				"type": "message", "workspace": w.teamID, "channel": chID, "thread": threadTS,
				"mention": w.isMention(w.chanKind[chID], text),
				"msg":     d.msgFromRaw(w, chID, uID, ts, text, rc, raw),
			})
			d.maybeNotify(w, chID, uID, text, threadTS)
			if threadTS != "" && threadTS != ts {
				// a live reply just landed — bump the parent's "N replies" in the channel view
				d.broadcast(map[string]any{"type": "replyCountInc", "workspace": w.teamID, "channel": chID, "ts": threadTS})
			}
		}
		rows.Close()

		// Detect read-state changes and push fresh unread counts.
		rr, err := db.QueryContext(ctx, `SELECT id, last_read_ts FROM channels WHERE workspace_id=?`, workspaceID)
		if err != nil {
			continue
		}
		type upd struct {
			id      string
			count   int
			mention bool
		}
		var updates []upd
		for rr.Next() {
			var id, lr string
			if rr.Scan(&id, &lr) != nil {
				continue
			}
			if lastRead[id] == lr {
				continue
			}
			lastRead[id] = lr
			if w.chans[id] == "" {
				continue
			}
			var n int
			db.QueryRowContext(ctx, `SELECT count(*) FROM messages
				WHERE channel_id=? AND ts>? AND is_deleted=0 AND text<>''
				      AND (thread_ts='' OR thread_ts=ts)`, id, lr).Scan(&n)
			updates = append(updates, upd{id, n, d.channelMention(w, id, w.chanKind[id], lr, n)})
		}
		rr.Close()
		for _, u := range updates {
			d.broadcast(map[string]any{"type": "unread", "workspace": w.teamID, "channel": u.id, "count": u.count, "mention": u.mention})
		}

		// Same for followed threads: a read in slk updates the subscription's
		// last_read, so push fresh per-thread unread counts.
		tr, err := db.QueryContext(ctx, `SELECT channel_id, thread_ts, last_read
			FROM thread_subscriptions WHERE workspace_id=? AND active=1`, workspaceID)
		if err != nil {
			continue
		}
		type tupd struct {
			cid, ts string
			count   int
		}
		var tupds []tupd
		for tr.Next() {
			var cid, tts, lr string
			if tr.Scan(&cid, &tts, &lr) != nil {
				continue
			}
			key := cid + "|" + tts
			if threadRead[key] == lr {
				continue
			}
			threadRead[key] = lr
			if w.chans[cid] == "" {
				continue
			}
			var n int
			db.QueryRowContext(ctx, `SELECT count(*) FROM messages
				WHERE channel_id=? AND thread_ts=? AND ts>? AND ts<>thread_ts
				      AND is_deleted=0 AND text<>''`, cid, tts, lr).Scan(&n)
			tupds = append(tupds, tupd{cid, tts, n})
		}
		tr.Close()
		for _, u := range tupds {
			d.broadcast(map[string]any{"type": "threadUnread", "workspace": w.teamID, "channel": u.cid, "thread": u.ts, "count": u.count})
		}
	}
}

// readConn handles client→daemon commands (send a message, request older
// history). Each accepted connection gets its own reader.
func (d *daemon) readConn(c net.Conn) {
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		// Channel carries a globally-unique Slack channel ID (the wire key),
		// so it resolves the owning workspace without a separate field.
		var cmd struct {
			Type, Channel, Text, Before, Thread, Id, Url, Ext, Mediatype, Ts, Emoji, Workspace, Team, State, User, Path string
			Remove, Broadcast                                                                                           bool
			Images                                                                                                      []struct{ Id, Url, Ext string } // "view" can carry several photos
		}
		if json.Unmarshal(sc.Bytes(), &cmd) != nil {
			continue
		}
		if cmd.Type == "testnotify" {
			log.Printf("testnotify -> err=%v", d.notifier.Notify("__test__", "slqs self-test", "if you see this, the daemon notifier delivers", ""))
			continue
		}
		// browse/join act on channels we may not be a member of yet, so they
		// resolve the workspace explicitly (not via the channel-id index).
		if cmd.Type == "browse" {
			if bw := d.wss[cmd.Workspace]; bw != nil {
				go d.sendBrowse(c, bw)
			}
			continue
		}
		if cmd.Type == "join" {
			jw := d.wss[cmd.Workspace]
			if jw == nil && cmd.Team != "" { // permalink join: route by subdomain
				for _, ws := range d.wsList {
					if ws.client.TeamSubdomain() == cmd.Team {
						jw = ws
						break
					}
				}
			}
			if jw != nil {
				go d.joinChannel(jw, cmd.Channel, cmd.Text)
			}
			continue
		}
		// openDM starts (or reopens) a 1:1 DM with a user we may have no channel
		// for yet, so it routes by workspace and registers the returned channel.
		if cmd.Type == "openDM" {
			dw := d.wss[cmd.Workspace]
			if dw != nil && cmd.User != "" {
				user := cmd.User
				go func(w *workspace) {
					chID, _, err := w.client.OpenConversation(d.ctx, []string{user})
					if err != nil {
						log.Printf("openDM: %v", err)
						d.broadcast(map[string]any{"type": "toast", "text": "Couldn't open DM"})
						return
					}
					d.registerChannel(w, slack.Channel{
						GroupConversation: slack.GroupConversation{Conversation: slack.Conversation{ID: chID, User: user, IsIM: true}},
					})
					d.broadcast(map[string]any{"type": "open", "workspace": w.teamID, "channel": chID, "thread": ""})
				}(dw)
			}
			continue
		}
		// invite adds a user to the current channel (conversations.invite). Route
		// by workspace, fall back to the channel-id index.
		if cmd.Type == "invite" {
			iw := d.wss[cmd.Workspace]
			if iw == nil {
				iw = d.idIndex[cmd.Channel]
			}
			if iw != nil && cmd.Channel != "" && cmd.User != "" {
				ch, user := cmd.Channel, cmd.User
				go func(w *workspace) {
					if err := w.client.InviteToConversation(d.ctx, ch, user); err != nil {
						log.Printf("invite: %v", err)
						d.broadcast(map[string]any{"type": "toast", "text": "Invite failed"})
						return
					}
					d.broadcast(map[string]any{"type": "toast", "text": "Invited to channel"})
				}(iw)
			}
			continue
		}
		w := d.idIndex[cmd.Channel]
		// "view" acts on a file — download the full-res original (authed with
		// the channel's workspace token) and report its local path.
		if cmd.Type == "view" {
			if w == nil {
				continue
			}
			items := cmd.Images
			if len(items) == 0 && cmd.Url != "" { // single-item fallback (older shape)
				items = append(items, struct{ Id, Url, Ext string }{cmd.Id, cmd.Url, cmd.Ext})
			}
			mediatype := cmd.Mediatype
			go func(w *workspace) {
				// Full-res originals land in a dedicated, easy-to-purge dir
				// (~/.cache/slqs/view) kept apart from the inline thumbnail cache.
				viewDir := filepath.Join(os.Getenv("HOME"), ".cache", "slqs", "view")
				os.MkdirAll(viewDir, 0755)
				var paths []string
				for _, im := range items {
					ext := im.Ext
					if ext == "" {
						ext = "jpg"
					}
					dst := filepath.Join(viewDir, im.Id+"."+ext)
					d.downloadFile(dst, im.Url, w.token, w.cookie)
					if _, err := os.Stat(dst); err == nil {
						paths = append(paths, "file://"+dst)
					}
				}
				if len(paths) > 0 {
					b, _ := json.Marshal(map[string]any{"type": "viewReady", "paths": paths, "mediatype": mediatype})
					b = append(b, '\n')
					d.mu.Lock()
					c.Write(b)
					d.mu.Unlock()
				}
			}(w)
			continue
		}
		// "focus" tells us what the client is viewing, so notifications for the
		// active channel are suppressed (matches slk). Channel may be empty.
		if cmd.Type == "focus" {
			d.focusMu.Lock()
			d.activeCh = cmd.Channel
			if w != nil {
				d.activeWS = w.teamID
			} else {
				d.activeWS = ""
			}
			d.focusMu.Unlock()
			continue
		}
		// Presence: while you're active on the computer we report "auto" (Slack
		// treats a connected client as active and holds mobile push); when idle we
		// report "away" so Slack resumes pushing to your phone.
		if cmd.Type == "presence" {
			presence := "auto"
			if cmd.State == "idle" {
				presence = "away"
			}
			d.presenceActive.Store(presence == "auto")
			for _, w := range d.wsList {
				go func(w *workspace) {
					if err := w.client.SetUserPresence(d.ctx, presence); err != nil {
						log.Printf("[%s] set presence %s: %v", w.teamName, presence, err)
					}
					if presence == "auto" {
						_ = w.client.Tickle() // report activity right away so you flip active without waiting a tick
					}
				}(w)
			}
			log.Printf("presence -> %s (%d ws)", presence, len(d.wsList))
			continue
		}
		// Opening the Threads view re-syncs the followed-threads list LIVE from
		// Slack (subscriptions.thread.getView) so last_read reflects reads made
		// in the official client — otherwise a thread read elsewhere keeps
		// showing a false unread. Parallel per workspace, then re-push.
		if cmd.Type == "refreshMentions" {
			go func(c net.Conn) {
				items := []map[string]any{}
				for _, w := range d.wsList {
					items = append(items, d.buildMentions(w)...)
				}
				d.writeConn(c, map[string]any{"type": "mentions", "items": items})
			}(c)
			continue
		}
		if cmd.Type == "refreshThreads" {
			go func() {
				var wg sync.WaitGroup
				for _, w := range d.wsList {
					wg.Add(1)
					go func(w *workspace) { defer wg.Done(); d.backfillSubscriptions(w) }(w)
				}
				wg.Wait()
				d.sendChannels(c)
			}()
			continue
		}
		// Manual update check (⌃⇧r): force a check now, ignoring the poll
		// cadence, and toast the result so the user gets feedback either way.
		if cmd.Type == "checkUpdate" {
			go func(c net.Conn) {
				if gitRev == "" {
					d.writeConn(c, map[string]any{"type": "toast", "text": "Dev build — update check unavailable"})
					return
				}
				d.checkUpdate(d.ctx)
				d.mu.Lock()
				ue := d.updateEvent
				d.mu.Unlock()
				if ue != nil {
					d.writeConn(c, map[string]any{"type": "toast", "text": "Update available — restart to apply"})
				} else {
					d.writeConn(c, map[string]any{"type": "toast", "text": "Up to date"})
				}
			}(c)
			continue
		}
		// Permalink jump — MUST run before the nil-workspace guard: the whole
		// point is channels we're not a member of (w == nil), resolved by the
		// permalink's team subdomain instead.
		if cmd.Type == "jump" {
			jw := w
			if jw == nil && cmd.Team != "" {
				for _, ws := range d.wsList {
					if ws.client.TeamSubdomain() == cmd.Team {
						jw = ws
						break
					}
				}
			}
			log.Printf("JUMP-DBG recv channel=%s ts=%s team=%q idIndexHit=%v resolved=%v",
				cmd.Channel, cmd.Ts, cmd.Team, w != nil, jw != nil)
			go d.sendJump(c, jw, cmd.Channel, cmd.Ts)
			continue
		}
		if w == nil {
			continue
		}
		id := cmd.Channel
		switch cmd.Type {
		case "typing":
			if id != "" {
				w.client.SendTyping(id)
			}
		case "send":
			go func(w *workspace) {
				// If an image is still uploading for this channel, wait so it
				// attaches to THIS message (not the next one).
				d.attachMu.Lock()
				done := d.uploading[id]
				d.attachMu.Unlock()
				if done != nil {
					select {
					case <-done:
					case <-time.After(20 * time.Second):
					}
				}
				// A staged image (from a prior paste) posts with this message.
				d.attachMu.Lock()
				fileID := d.pendingAttach[id]
				attThread := d.pendingAttachThread[id]
				delete(d.pendingAttach, id)
				delete(d.pendingAttachThread, id)
				d.attachMu.Unlock()
				var err error
				if fileID != "" {
					// The attachment carries the thread it was staged in, so it
					// lands there no matter which composer triggered the send.
					t := cmd.Thread
					if attThread != "" {
						t = attThread
					}
					var permalink string
					permalink, err = w.client.CompleteUpload(d.ctx, id, t, fileID, cmd.Text)
					// Slack's file API can't broadcast a threaded upload to the
					// channel, so post the permalink as a broadcast reply — the
					// channel then shows the unfurled file.
					if err == nil && cmd.Broadcast && t != "" && permalink != "" {
						_, _, err = w.client.SendReply(d.ctx, id, t, permalink, true)
					}
				} else if cmd.Thread != "" {
					_, _, err = w.client.SendReply(d.ctx, id, cmd.Thread, cmd.Text, cmd.Broadcast)
				} else {
					_, _, err = w.client.SendMessage(d.ctx, id, cmd.Text)
				}
				if err != nil {
					log.Printf("send: %v", err)
				}
			}(w)
		case "edit":
			go func(w *workspace) {
				if _, err := w.client.EditMessage(d.ctx, id, cmd.Ts, cmd.Text); err != nil {
					log.Printf("edit: %v", err)
				}
			}(w)
		case "delete":
			go func(w *workspace) {
				if err := w.client.RemoveMessage(d.ctx, id, cmd.Ts); err != nil {
					log.Printf("delete: %v", err)
				}
			}(w)
		case "react":
			go func(w *workspace, channelID, ts string) {
				// Reacting to a threaded message makes Slack auto-follow that
				// thread. Capture whether we already followed it BEFORE reacting,
				// so we can undo the auto-follow without unfollowing a thread we
				// chose to follow (by replying/opening).
				var rootTS string
				var wasSub bool
				if !cmd.Remove {
					if m, gErr := d.writeDB.GetMessage(channelID, ts); gErr == nil {
						if m.ThreadTS != "" {
							rootTS = m.ThreadTS
						} else if m.ReplyCount > 0 {
							rootTS = m.TS
						}
						if rootTS != "" {
							wasSub, _ = d.writeDB.IsThreadSubscribed(w.teamID, channelID, rootTS)
						}
					}
				}

				var err error
				if cmd.Remove {
					err = w.client.RemoveReaction(d.ctx, channelID, ts, cmd.Emoji)
				} else {
					err = w.client.AddReaction(d.ctx, channelID, ts, cmd.Emoji)
				}
				added := err == nil && !cmd.Remove
				if err != nil {
					// already_reacted (add) / no_reaction (remove) mean the desired
					// end state already holds — fall through to broadcast so the UI
					// converges instead of looking stuck.
					if es := err.Error(); !strings.Contains(es, "already_reacted") && !strings.Contains(es, "no_reaction") {
						log.Printf("react: %v", err)
						return
					}
				}

				// Undo Slack's react-triggered thread follow when we weren't
				// already following it (only on a fresh add). The server records
				// the follow as part of processing the reaction, so give it a beat.
				if added && rootTS != "" && !wasSub {
					time.Sleep(500 * time.Millisecond)
					if uErr := w.client.UnsubscribeThread(d.ctx, channelID, rootTS); uErr != nil {
						log.Printf("react: undo auto-follow: %v", uErr)
					} else {
						d.writeDB.UpsertThreadSubscription(w.teamID, channelID, rootTS, "", false)
						d.markThreadsDirty()
					}
				}
				// slk's websocket writes the reaction to cache.db shortly after;
				// re-read and broadcast the authoritative set (twice, to catch it).
				for _, delay := range []time.Duration{350 * time.Millisecond, 1 * time.Second} {
					time.Sleep(delay)
					d.broadcast(map[string]any{"type": "reaction", "workspace": w.teamID,
						"channel": channelID, "ts": ts, "reactionsJson": d.reactionsJSONFor(w, channelID, ts)})
				}
			}(w, id, cmd.Ts)
		case "uploadClipboard":
			// Paste an image from the Wayland clipboard (e.g. a grim screenshot)
			// into the channel/thread. No-op if the clipboard holds no image.
			// Register the in-flight upload SYNCHRONOUSLY (before the goroutine) so
			// a "send" read next always observes it and waits for the staged image —
			// otherwise a quick paste+send races and the image posts with the
			// following message instead of this one.
			thread := cmd.Thread
			done := make(chan struct{})
			d.attachMu.Lock()
			d.uploading[id] = done
			d.attachMu.Unlock()
			go func(w *workspace) {
				defer close(done) // release any send waiting on this upload
				types, _ := exec.Command("wl-paste", "--list-types").Output()
				var mime, ext string
				switch t := string(types); {
				case strings.Contains(t, "image/png"):
					mime, ext = "image/png", "png"
				case strings.Contains(t, "image/jpeg"):
					mime, ext = "image/jpeg", "jpg"
				case strings.Contains(t, "image/gif"):
					mime, ext = "image/gif", "gif"
				default:
					// text paste, not an image — clear the optimistic "uploading" badge
					d.broadcast(map[string]any{"type": "attachReady", "channel": id, "name": "", "ok": false})
					return
				}
				fail := func(reason string) {
					d.broadcast(map[string]any{"type": "attachReady", "channel": id, "name": "", "ok": false, "err": reason})
				}
				data, err := exec.Command("wl-paste", "-t", mime).Output()
				if err != nil || len(data) == 0 {
					fail("clipboard image was empty")
					return
				}
				name := "pasted." + ext
				// Show an "uploading" state immediately + hand the UI the local file
				// (for an optimistic preview) before the upload finishes.
				tmp := "/tmp/slqs-paste." + ext
				_ = os.WriteFile(tmp, data, 0o600)
				d.broadcast(map[string]any{"type": "attachUploading", "channel": id, "name": name, "path": "file://" + tmp})
				// Stage (upload but don't post) — the next message posts it.
				fileID, err := w.client.StageUpload(d.ctx, name, data)
				if err != nil {
					log.Printf("upload: %v", err)
					fail("upload failed: " + err.Error())
					return
				}
				d.attachMu.Lock()
				d.pendingAttach[id] = fileID
				d.pendingAttachThread[id] = thread
				d.attachMu.Unlock()
				d.broadcast(map[string]any{"type": "attachReady", "channel": id, "name": name, "ok": true})
			}(w)
		case "uploadFile":
			// Upload any file from disk (screen recordings, PDFs, …). Same
			// staging flow as uploadClipboard — Slack infers the type from the
			// name; the next "send" posts it. Register the in-flight upload
			// synchronously so a quick send waits for it.
			path := cmd.Path
			thread := cmd.Thread
			done := make(chan struct{})
			d.attachMu.Lock()
			d.uploading[id] = done
			d.attachMu.Unlock()
			go func(w *workspace) {
				defer close(done)
				fail := func(reason string) {
					d.broadcast(map[string]any{"type": "attachReady", "channel": id, "name": "", "ok": false, "err": reason})
				}
				data, err := os.ReadFile(path)
				if err != nil || len(data) == 0 {
					log.Printf("uploadFile read %s: %v", path, err)
					fail("can't read " + path)
					return
				}
				name := filepath.Base(path)
				// Optimistic preview only makes sense for images; other files
				// just show the name chip.
				preview := ""
				switch strings.ToLower(filepath.Ext(name)) {
				case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp":
					preview = "file://" + path
				}
				d.broadcast(map[string]any{"type": "attachUploading", "channel": id, "name": name, "path": preview})
				fileID, err := w.client.StageUpload(d.ctx, name, data)
				if err != nil {
					log.Printf("uploadFile stage: %v", err)
					fail("upload failed: " + err.Error())
					return
				}
				d.attachMu.Lock()
				d.pendingAttach[id] = fileID
				d.pendingAttachThread[id] = thread
				d.attachMu.Unlock()
				d.broadcast(map[string]any{"type": "attachReady", "channel": id, "name": name, "ok": true})
			}(w)
		case "dropAttach":
			d.attachMu.Lock()
			delete(d.pendingAttach, id)
			delete(d.pendingAttachThread, id)
			d.attachMu.Unlock()
		case "recent":
			d.focusMu.Lock()
			d.activeCh = id
			if w != nil {
				d.activeWS = w.teamID
			}
			d.focusMu.Unlock()
			go d.sendRecent(c, w, id)
			go d.watchChannelPresence(w, id)
		case "history":
			go d.sendHistory(c, w, id, cmd.Before)
		case "replies":
			go d.sendReplies(c, w, id, cmd.Thread)
		case "unsubThread":
			// Unfollow a thread (from the Threads view): tell Slack, drop it from
			// the cache, and re-push the list so it disappears.
			if cmd.Thread != "" {
				go func(w *workspace, ch, tts string) {
					if err := w.client.UnsubscribeThread(d.ctx, ch, tts); err != nil {
						log.Printf("unsubThread: %v", err)
					}
					d.writeDB.DeleteThreadSubscription(w.teamID, ch, tts)
					d.markThreadsDirty()
				}(w, id, cmd.Thread)
			}
		case "markThreadRead":
			// A reply landed in the thread the client currently has open, so it's
			// been seen — advance read-state (and mark it on Slack if we follow it)
			// and re-push the threads list so it doesn't sit as unread while you read.
			if w != nil && cmd.Thread != "" && cmd.Ts != "" {
				go func(w *workspace, ch, tts, ts string) {
					d.writeDB.AdvanceThreadSubscriptionLastRead(w.teamID, ch, tts, ts)
					var active int
					d.cacheDB.QueryRowContext(d.ctx,
						`SELECT active FROM thread_subscriptions WHERE workspace_id=? AND channel_id=? AND thread_ts=?`,
						w.teamID, ch, tts).Scan(&active)
					if active == 1 {
						if err := w.client.MarkThread(d.ctx, ch, tts, ts); err != nil {
							log.Printf("markThreadRead: %v", err)
						}
					}
					d.markThreadsDirty()
				}(w, id, cmd.Thread, cmd.Ts)
			}
		case "markread":
			// Opening a channel marks it read on the server (Before carries the
			// latest message ts), so it doesn't resurface as unread elsewhere.
			if cmd.Before != "" {
				// Update local read-state immediately. Slack's im_marked/
				// channel_marked echo is unreliable (esp. for DMs), so relying on
				// it alone left read DMs stuck unread after every recompute/restart.
				d.writeDB.UpdateChannelReadState(id, cmd.Before, false)
				go func(w *workspace) {
					if err := w.client.MarkChannel(d.ctx, id, cmd.Before); err != nil {
						log.Printf("markread: %v", err)
					}
				}(w)
			}
		}
	}
	d.mu.Lock()
	delete(d.conns, c)
	d.mu.Unlock()
	c.Close()
}

func (d *daemon) sendHistory(c net.Conn, w *workspace, channelID, before string) {
	msgs, err := w.client.GetOlderHistory(d.ctx, channelID, 50, before)
	if err != nil {
		log.Printf("history: %v", err)
		return
	}
	sort.Slice(msgs, func(i, j int) bool { return msgs[i].Timestamp < msgs[j].Timestamp })
	d.resolveMsgAuthors(w, msgs)
	out := make([]map[string]any, 0, len(msgs))
	for _, m := range msgs {
		text := displayText(m)
		if text == "" && len(m.Files) == 0 {
			continue
		}
		out = append(out, d.formatMsg(w, channelID, authorOf(m), m.Timestamp, text, m.Username, m.Files, m.Attachments, m.SubType, m.ThreadTimestamp))
	}
	b, _ := json.Marshal(map[string]any{"type": "history", "workspace": w.teamID, "channel": channelID, "msgs": out})
	b = append(b, '\n')
	d.mu.Lock()
	c.Write(b)
	d.mu.Unlock()
}

func (d *daemon) sendJump(c net.Conn, w *workspace, channelID, ts string) {
	if w == nil || ts == "" {
		d.sendJumpFailed(c, channelID)
		return
	}
	msgs, err := w.client.GetHistoryAround(d.ctx, channelID, ts, 30)
	if err != nil {
		// Private channel we're not in / no access — let the client fall back to
		// the browser instead of leaving it hanging.
		log.Printf("JUMP-DBG GetHistoryAround err: %v", err)
		d.sendJumpFailed(c, channelID)
		return
	}
	log.Printf("JUMP-DBG GetHistoryAround ok: %d msgs, joined=%v", len(msgs), w.chans[channelID] != "")
	sort.Slice(msgs, func(i, j int) bool { return msgs[i].Timestamp < msgs[j].Timestamp })
	d.resolveMsgAuthors(w, msgs)
	out := make([]map[string]any, 0, len(msgs))
	for _, m := range msgs {
		text := displayText(m)
		if text == "" && len(m.Files) == 0 {
			continue
		}
		out = append(out, d.formatMsg(w, channelID, authorOf(m), m.Timestamp, text, m.Username, m.Files, m.Attachments, m.SubType, m.ThreadTimestamp))
	}
	// Channel name for the header — from the joined list, else conversations.info
	// (jump into a public channel we haven't joined).
	joined := w.chans[channelID] != ""
	chName := w.chans[channelID]
	if chName == "" {
		chName = w.client.ChannelName(d.ctx, channelID)
	}
	// Reset the channel view to this window; "jump" tells the client which ts to
	// scroll to and flash once the batch lands. "joined"=false lets the client
	// offer a Join action for a channel we're only previewing.
	b, _ := json.Marshal(map[string]any{
		"type": "recent", "workspace": w.teamID, "channel": channelID,
		"msgs": out, "reset": true, "final": true, "jump": ts, "channelName": chName, "joined": joined,
	})
	b = append(b, '\n')
	d.mu.Lock()
	c.Write(b)
	d.mu.Unlock()
}

func (d *daemon) sendJumpFailed(c net.Conn, channelID string) {
	b, _ := json.Marshal(map[string]any{"type": "jumpFailed", "channel": channelID})
	b = append(b, '\n')
	d.mu.Lock()
	c.Write(b)
	d.mu.Unlock()
}

func (d *daemon) sendReplies(c net.Conn, w *workspace, channelID, threadTS string) {
	if w == nil {
		return
	}
	msgs, err := w.client.GetReplies(d.ctx, channelID, threadTS)
	if err != nil {
		log.Printf("replies: %v", err)
		return
	}
	sort.Slice(msgs, func(i, j int) bool { return msgs[i].Timestamp < msgs[j].Timestamp })
	// Opening a thread is a read action: persist the live replies (so the
	// threads-view unread count is accurate) and mark the thread read up to the
	// latest reply on Slack + cache, so it doesn't flip back to unread on the
	// next rebuild. Authoritative latest ts from the live fetch — no race.
	var latest string
	for _, m := range msgs {
		d.persistMessage(w, channelID, m)
		if m.Timestamp > latest {
			latest = m.Timestamp
		}
	}
	if latest != "" {
		// Advance read-state for an EXISTING subscription only (no-op otherwise).
		d.writeDB.AdvanceThreadSubscriptionLastRead(w.teamID, channelID, threadTS, latest)
		// Only tell Slack we've read it when we ALREADY follow it. Calling
		// subscriptions.thread.mark on a thread we don't follow risks subscribing
		// us — so opening a thread just to read/type never subscribes.
		var active int
		d.cacheDB.QueryRowContext(d.ctx,
			`SELECT active FROM thread_subscriptions WHERE workspace_id=? AND channel_id=? AND thread_ts=?`,
			w.teamID, channelID, threadTS).Scan(&active)
		if active == 1 {
			go func() {
				if err := w.client.MarkThread(d.ctx, channelID, threadTS, latest); err != nil {
					log.Printf("markThread: %v", err)
				}
			}()
		}
	}
	d.resolveMsgAuthors(w, msgs)
	out := make([]map[string]any, 0, len(msgs))
	for _, m := range msgs {
		text := displayText(m)
		if text == "" && len(m.Files) == 0 {
			continue
		}
		out = append(out, d.formatMsg(w, channelID, authorOf(m), m.Timestamp, text, m.Username, m.Files, m.Attachments, m.SubType, m.ThreadTimestamp))
	}
	b, _ := json.Marshal(map[string]any{"type": "replies", "workspace": w.teamID, "channel": channelID, "thread": threadTS, "msgs": out})
	b = append(b, '\n')
	d.mu.Lock()
	c.Write(b)
	d.mu.Unlock()
}

// maybeNotify fires a desktop notification for a new message using slk's own
// ShouldNotify rules (DM/mention/watched, skipping own messages and the
// channel the client is actively viewing), so notifications match slk.
func (d *daemon) maybeNotify(w *workspace, chID, uID, text, threadTS string) {
	chName := w.chans[chID]
	d.focusMu.RLock()
	// Suppress only when the focused client is viewing THIS channel in THIS
	// workspace (ShouldNotify combines IsActiveWS with ActiveChannelID).
	activeHere := d.appActive && d.activeWS == w.teamID
	active := d.activeCh
	dbgActiveWS := d.activeWS
	dbgAppActive := d.appActive
	d.focusMu.RUnlock()
	// A reply in a thread you follow (Slack auto-subscribes you to threads you
	// start, reply to, or are @-mentioned in) should notify even without an @.
	threadFollowed := false
	if threadTS != "" {
		if sub, err := d.writeDB.IsThreadSubscribed(w.teamID, chID, threadTS); err == nil {
			threadFollowed = sub
		}
	}
	ctx := notify.NotifyContext{
		CurrentUserID:   w.selfID,
		ActiveChannelID: active,
		IsActiveWS:      activeHere,
		OnMention:       true,
		OnDM:            true,
		OnThread:        true,
		ThreadFollowed:  threadFollowed,
		ChannelName:     chName,
	}
	kind := w.chanKind[chID]
	should := notify.ShouldNotify(ctx, chID, uID, text, kind)
	log.Printf("notify-dbg: [%s] ch=%s kind=%s from=%s self=%s appActive=%v activeWS=%s activeHere=%v activeCh=%s mentionSelf=%v threadFollowed=%v own=%v -> should=%v",
		w.teamName, chName, kind, uID, w.selfID, dbgAppActive, dbgActiveWS, activeHere, active,
		strings.Contains(text, "<@"+w.selfID+">"), threadFollowed, uID == w.selfID, should)
	if !should {
		return
	}
	author := w.users[uID]
	if author == "" {
		author = chName
	}
	title := author
	if kind != "dm" {
		title = author + " in #" + chName
	}
	if len(d.wsList) > 1 {
		title += " · " + w.teamName
	}
	body := stripMentionMarks(d.render(w, text))
	if body == "" {
		body = "sent an attachment"
	}
	log.Printf("notify: [%s] ch=%s kind=%s from=%s", w.teamName, chName, kind, uID)
	d.notifier.Notify(notify.RouteKey(w.teamID, chID, threadTS), title, body, d.avatarPath(uID))
}

// onNotifActivate fires when a notification is clicked: open that channel
// (in its workspace) in the client and raise its window.
func (d *daemon) onNotifActivate(key string) {
	teamID, chID, threadTS := notify.ParseRouteKey(key)
	w := d.wss[teamID]
	if w == nil || w.chans[chID] == "" {
		return
	}
	open := map[string]any{"type": "open", "workspace": teamID, "channel": chID, "thread": threadTS}
	d.mu.Lock()
	hasClient := len(d.conns) > 0
	d.mu.Unlock()
	if hasClient {
		// threadTS set → the notification was a thread reply; open that thread.
		d.broadcast(open)
		// The client is the only org.quickshell *toplevel* (the bar is layer-shell).
		go exec.Command("sh", "-c",
			`id=$(niri msg --json windows | jq -r '[.[]|select(.app_id=="org.quickshell")][0].id'); [ -n "$id" ] && niri msg action focus-window --id "$id"`).Run()
		return
	}
	// No client window open — stash the target so the next connection opens it,
	// then launch the client.
	d.focusMu.Lock()
	d.pendingOpen = open
	d.focusMu.Unlock()
	go exec.Command("sh", "-c", os.Getenv("HOME")+"/.config/niri/scripts/launch-slack-client").Run()
}

// watchNiriFocus follows niri's JSON event stream and flips d.appActive based
// on whether the focused window is our org.quickshell client. Restarts the
// stream if niri drops it.
func (d *daemon) watchNiriFocus(ctx context.Context) {
	type niriWin struct {
		ID        uint64 `json:"id"`
		AppID     string `json:"app_id"`
		IsFocused bool   `json:"is_focused"`
	}
	for ctx.Err() == nil {
		cmd := exec.CommandContext(ctx, "niri", "msg", "--json", "event-stream")
		out, err := cmd.StdoutPipe()
		if err != nil {
			time.Sleep(2 * time.Second)
			continue
		}
		if err := cmd.Start(); err != nil {
			time.Sleep(2 * time.Second)
			continue
		}
		qsWins := map[uint64]bool{} // window id -> is our client
		var focused uint64
		apply := func() {
			d.focusMu.Lock()
			d.appActive = focused != 0 && qsWins[focused]
			d.focusMu.Unlock()
		}
		sc := bufio.NewScanner(out)
		sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
		for sc.Scan() {
			var ev map[string]json.RawMessage
			if json.Unmarshal(sc.Bytes(), &ev) != nil {
				continue
			}
			if raw, ok := ev["WindowsChanged"]; ok {
				var p struct {
					Windows []niriWin `json:"windows"`
				}
				if json.Unmarshal(raw, &p) == nil {
					qsWins = map[uint64]bool{}
					for _, w := range p.Windows {
						qsWins[w.ID] = w.AppID == "org.quickshell"
						if w.IsFocused {
							focused = w.ID
						}
					}
					apply()
				}
			} else if raw, ok := ev["WindowOpenedOrChanged"]; ok {
				var p struct {
					Window niriWin `json:"window"`
				}
				if json.Unmarshal(raw, &p) == nil {
					qsWins[p.Window.ID] = p.Window.AppID == "org.quickshell"
					if p.Window.IsFocused {
						focused = p.Window.ID
					}
					apply()
				}
			} else if raw, ok := ev["WindowClosed"]; ok {
				var p struct {
					ID uint64 `json:"id"`
				}
				if json.Unmarshal(raw, &p) == nil {
					delete(qsWins, p.ID)
					if focused == p.ID {
						focused = 0
					}
					apply()
				}
			} else if raw, ok := ev["WindowFocusChanged"]; ok {
				var p struct {
					ID *uint64 `json:"id"`
				}
				if json.Unmarshal(raw, &p) == nil {
					if p.ID == nil {
						focused = 0
					} else {
						focused = *p.ID
					}
					apply()
				}
			}
		}
		cmd.Wait()
		time.Sleep(time.Second)
	}
}

// addWorkspace authenticates one token and builds its workspace state (users,
// channels, DM names, topics). Returns the user list for avatar prefetch.
func (d *daemon) addWorkspace(ctx context.Context, tok slackclient.Token) (*workspace, []slack.User, error) {
	client := slackclient.NewClient(tok.AccessToken, tok.Cookie)
	if err := client.Connect(ctx); err != nil {
		return nil, nil, err
	}
	w := &workspace{
		teamID:   client.TeamID(),
		teamName: tok.TeamName,
		token:    tok.AccessToken,
		cookie:   tok.Cookie,
		selfID:   client.UserID(),
		client:   client,
		users:    map[string]string{},
		chans:    map[string]string{},
		chanKind: map[string]string{},
		topics:   map[string]string{},
		dmUser:   map[string]string{},
		subteams: map[string]string{},
		presence: map[string]string{},
		presSubs: map[string]struct{}{},
		status:   map[string]string{},
	}
	// Per-workspace name style: WAG shows Slack display names, others (Lovable)
	// the full real name.
	w.namePref = "real"
	if w.teamName == "WAG" {
		w.namePref = "display"
	}
	var users []slack.User
	if us, err := client.GetUsers(ctx); err == nil {
		users = us
		for _, u := range us {
			w.users[u.ID] = nameFor(u, w.namePref)
			if e := strings.Trim(u.Profile.StatusEmoji, ":"); e != "" {
				w.status[u.ID] = emojiGlyph(e)
			}
		}
	}
	if handles, member, err := client.GetUsergroups(ctx, w.selfID); err == nil {
		w.subteams = handles
		for id := range member {
			w.myGroups = append(w.myGroups, id)
		}
	}
	if cs, err := client.GetChannels(ctx); err == nil {
		for _, c := range cs {
			kind := "channel"
			name := cleanName(c.Name)
			switch {
			case c.IsIM: // 1:1 DM — no name in the API; resolve the other user
				kind = "dm"
				name = w.users[c.User]
				if name == "" {
					name = c.User
				}
			case c.IsMpIM: // group DM
				kind = "dm"
			}
			if name == "" {
				continue
			}
			w.chans[c.ID] = name
			w.chanKind[c.ID] = kind
			w.topics[c.ID] = c.Topic.Value
			if c.IsIM {
				w.dmUser[c.ID] = c.User
			}
		}
	}
	log.Printf("[%s] %s: %d users, %d channels", w.teamName, w.teamID, len(w.users), len(w.chans))
	return w, users, nil
}

// cacheCustomEmoji downloads a workspace's custom emoji into the shared cache
// and records name→file:// paths under into[teamID], then rewrites emoji.json
// (nested by workspace, so the client can scope the picker to one team). Cache
// files are namespaced by team so same-named emoji in different teams don't clash.
func (d *daemon) cacheCustomEmoji(ctx context.Context, w *workspace, into map[string]map[string]string, mu *sync.Mutex) {
	em, err := w.client.ListCustomEmoji(ctx)
	if err != nil {
		log.Printf("[%s] custom emoji: %v", w.teamName, err)
		return
	}
	dir := filepath.Join(os.Getenv("HOME"), ".cache", "slqs", "emoji")
	os.MkdirAll(dir, 0755)
	record := func(name, path string) {
		mu.Lock()
		if into[w.teamID] == nil {
			into[w.teamID] = map[string]string{}
		}
		into[w.teamID][name] = path
		mu.Unlock()
	}
	sem := make(chan struct{}, 8)
	var wg sync.WaitGroup
	for name, url := range em {
		for strings.HasPrefix(url, "alias:") { // follow alias chains
			if u, ok := em[strings.TrimPrefix(url, "alias:")]; ok {
				url = u
			} else {
				break
			}
		}
		if !strings.HasPrefix(url, "http") {
			continue
		}
		ext := "png"
		if i := strings.LastIndexByte(url, '.'); i >= 0 && len(url)-i <= 5 {
			ext = strings.ToLower(url[i+1:])
		}
		dst := filepath.Join(dir, w.teamID+"-"+name+"."+ext)
		path := "file://" + dst
		if _, err := os.Stat(dst); err == nil { // already cached
			record(name, path)
			continue
		}
		wg.Add(1)
		go func(name, url, dst, path string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			resp, err := http.Get(url)
			if err != nil || resp.StatusCode != 200 {
				if resp != nil {
					resp.Body.Close()
				}
				return
			}
			b, err := io.ReadAll(resp.Body)
			resp.Body.Close()
			if err != nil {
				return
			}
			if os.WriteFile(dst, b, 0644) == nil {
				record(name, path)
			}
		}(name, url, dst, path)
	}
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	os.MkdirAll(xdgData(), 0700)
	out := filepath.Join(xdgData(), "emoji.json")
	if b, err := json.Marshal(into); err == nil {
		os.WriteFile(out, b, 0644)
		log.Printf("[%s] custom emoji cached (%d)", w.teamName, len(into[w.teamID]))
	}
}

// markThreadsDirty schedules a debounced threads-list re-push. Live thread
// activity (a reply, a new subscription, a read elsewhere) updates the cache via
// the websocket; this coalesces a burst into one rebuild so the Threads view
// updates in real time without a getView per event. Mirrors slk's
// ThreadsListDirtyMsg -> debounced re-fetch.
func (d *daemon) markThreadsDirty() {
	d.threadsDirtyMu.Lock()
	defer d.threadsDirtyMu.Unlock()
	if d.threadsDirtyTimer != nil {
		d.threadsDirtyTimer.Stop()
	}
	d.threadsDirtyTimer = time.AfterFunc(1500*time.Millisecond, d.refreshChannels)
}

// refreshChannels re-sends the channel list (+ subThreads) to every connected
// client, so a thread/subscription refresh shows up without a reconnect.
func (d *daemon) refreshChannels() {
	d.mu.Lock()
	conns := make([]net.Conn, 0, len(d.conns))
	for c := range d.conns {
		conns = append(conns, c)
	}
	d.mu.Unlock()
	for _, c := range conns {
		d.sendChannels(c)
	}
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	store := slackclient.NewTokenStore(filepath.Join(xdgData(), "tokens"))
	tokens, err := store.List()
	if err != nil || len(tokens) == 0 {
		log.Fatal("no slk tokens found — run slk at least once to authenticate")
	}

	d := &daemon{
		ctx:                 ctx,
		wss:                 map[string]*workspace{},
		idIndex:             map[string]*workspace{},
		avatars:             map[string]string{},
		pendingAttach:       map[string]string{},
		pendingAttachThread: map[string]string{},
		uploading:           map[string]chan struct{}{},
		lastBackfill:        map[string]time.Time{},
		conns:               map[net.Conn]struct{}{},
		userMiss:            map[string]bool{},
	}
	cachePath := filepath.Join(xdgData(), "cache.db")
	dsn := "file:" + cachePath + "?mode=ro&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	if d.cacheDB, err = sql.Open("sqlite", dsn); err != nil {
		log.Fatalf("open cache.db: %v", err)
	}
	defer d.cacheDB.Close()
	// Read-write handle the websocket handler persists live events through
	// (runs migrations idempotently; WAL lets it coexist with the ro reader).
	if d.writeDB, err = cache.New(cachePath); err != nil {
		log.Fatalf("open cache.db (rw): %v", err)
	}
	defer d.writeDB.Close()

	d.notifier = notify.New(true)
	d.notifier.SetOnActivate(d.onNotifActivate)
	d.scanAvatars()

	// Custom emoji written to emoji.json nested by workspace (teamID → name →
	// path), so the client scopes the picker to the active team.
	customEmoji := map[string]map[string]string{}
	var emojiMu sync.Mutex

	for _, tok := range tokens {
		w, users, err := d.addWorkspace(ctx, tok)
		if err != nil {
			log.Printf("skip workspace %s (%s): %v", tok.TeamName, tok.TeamID, err)
			continue
		}
		d.wss[w.teamID] = w
		d.wsList = append(d.wsList, w)
		for id := range w.chans {
			d.idIndex[id] = w // channel IDs are globally unique → one global index
		}
		go d.pollWorkspace(ctx, w)
		// slqs's OWN Slack websocket — persists live events to cache.db so the
		// poll loop broadcasts them. This is what lets slk be retired entirely.
		go slackclient.NewConnectionManager(w.client, &wsHandler{d: d, w: w}).Run(ctx)
		go func(w *workspace, users []slack.User) {
			prefetchAvatars(users)
			d.scanAvatars()
			d.cacheCustomEmoji(ctx, w, customEmoji, &emojiMu)
		}(w, users)
	}
	if len(d.wsList) == 0 {
		log.Fatal("no usable workspaces")
	}
	// Suspend detection: monotonic pauses while wall time doesn't, so a
	// divergence means we slept. Websocket events from the gap were never
	// delivered — tell clients to refetch what they're showing.
	go func() {
		mono, wall := time.Now(), time.Now().Round(0)
		for {
			time.Sleep(5 * time.Second)
			m, w := time.Now(), time.Now().Round(0)
			if w.Sub(wall)-m.Sub(mono) > time.Minute {
				log.Printf("wake from suspend — resync")
				time.Sleep(5 * time.Second) // let the network come back first
				d.broadcast(map[string]any{"type": "resync"})
			}
			mono, wall = m, w
		}
	}()
	log.Printf("%d workspace(s) ready", len(d.wsList))

	// Mobile-push suppression: keep Slack's away timer reset while active by
	// sending a websocket "tickle" frame (the activity signal the real client
	// emits on input; users.setActive is a deprecated no-op). Without this Slack
	// auto-marks you away ~10 min after connect and pushes to your phone.
	// swayidle flips presenceActive off when idle, stopping the tickle so push
	// resumes when you're actually away.
	d.presenceActive.Store(true)
	go func() {
		ping := func() {
			if !d.presenceActive.Load() {
				return
			}
			for _, w := range d.wsList {
				go func(w *workspace) { _ = w.client.Tickle() }(w)
			}
		}
		ping() // immediately, so a fresh start is active without waiting a tick
		t := time.NewTicker(60 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				ping()
			}
		}
	}()

	// Standard shortcode→unicode table for the client's emoji picker/autocomplete.
	if b, err := json.Marshal(emojiMap); err == nil {
		os.MkdirAll(xdgData(), 0700)
		os.WriteFile(filepath.Join(xdgData(), "codemap.json"), b, 0644)
	}

	sock := socketPath()
	os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		log.Fatalf("listen %s: %v", sock, err)
	}
	defer os.Remove(sock)
	log.Printf("streaming events on %s", sock)

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			d.mu.Lock()
			d.conns[c] = struct{}{}
			ue := d.updateEvent
			d.mu.Unlock()
			log.Println("client connected")
			if ue != nil { // replay update-available state to a (re)connecting client
				if b, err := json.Marshal(ue); err == nil {
					c.Write(b)
				}
			}
			// A fresh client (app (re)start) → re-check for updates unless we
			// just did; the warm daemon otherwise only polls every 3h.
			if gitRev != "" {
				d.updMu.Lock()
				stale := time.Since(d.updLast) > time.Minute
				d.updMu.Unlock()
				if stale {
					go d.checkUpdate(ctx)
				}
			}
			go d.sendChannels(c)
			go d.readConn(c)
		}
	}()

	// Live messages come from watching slk's cache.db (per workspace, launched
	// above), NOT a second Slack websocket that would contend for the token.

	// Heartbeat: lets the client detect a dead socket (Quickshell's `connected`
	// stays stuck-true after a server-side close) and reconnect. Also prunes
	// dead conns server-side, since broadcast drops conns whose write fails.
	go func() {
		t := time.NewTicker(3 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				d.broadcast(map[string]any{"type": "ping"})
			}
		}
	}()

	// Update check: at start, every 3h, and on each client connect (see the
	// accept loop) — so restarting the app surfaces a new build immediately
	// instead of waiting on the warm daemon's next poll.
	if gitRev != "" {
		go func() {
			d.checkUpdate(ctx)
			t := time.NewTicker(3 * time.Hour)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					d.checkUpdate(ctx)
				}
			}
		}()
	}

	// Track whether the client window is focused via niri's event stream, so
	// notifications for the active channel are suppressed only while we're
	// actually looking at it (FloatingWindow exposes no focus property to QML).
	go d.watchNiriFocus(ctx)

	<-ctx.Done()
	ln.Close()
	log.Println("shutdown")
}
