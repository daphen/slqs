pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────
// Fully dynamic: all data comes live from slkd over the Unix socket. slkd reads
// slk's SQLite cache directly — channel list + followed threads on connect
// (`channels`), a channel's history on open (`recent`), and live events after.
// No static snapshot; cache.db is the single source of truth.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: backend

    property alias channels: channelsModel
    property alias messages: messagesModel
    property string currentChannel: ""     // display name of the open channel
    property string currentChannelId: ""   // wire key (globally-unique Slack id)
    property string currentTopic: ""
    property bool   typing: false
    property string typingWho: ""
    property bool   threadTyping: false
    property string threadTypingWho: ""

    // Update-available indicator. The daemon polls the repo's main SHA and pushes
    // an `updateAvailable` event when a newer build exists (detect-only — the host
    // applies it via flake bump + rebuild). Empty/quiet on source/dev builds.
    property bool   updateAvailable: false
    property string updateCurrent: ""
    property string updateLatest: ""
    function dismissUpdate() { updateAvailable = false }
    // `U` → run the host's apply command. Detect-only: the app never self-updates;
    // SLK_UPDATE_CMD is the host's "apply" step (e.g. bump the flake + rebuild +
    // restart). Runs via `sh -c` so the command can spawn its own terminal for sudo.
    function applyUpdate() {
        const cmd = Quickshell.env("SLK_UPDATE_CMD")
        if (cmd && cmd.length > 0) Quickshell.execDetached(["sh", "-c", cmd])
        else toast("No update command set — configure SLK_UPDATE_CMD")
    }

    // Multiple Slack workspaces. The sidebar shows one workspace at a time;
    // channels are keyed by id (names collide across workspaces).
    property var    workspaces: []          // [{id, name}]
    property bool   useRail: false          // vertical workspace rail (Discord) vs top tabs (Slack)
    // Hide the always-on rail and switch workspaces via the Ctrl+S picker instead.
    // Default on for Discord (many servers, mostly-DMs usage); the rail stays for
    // anything that still wants it.
    property bool   railHidden: Quickshell.env("SLK_SOCK") === "dsqrd"
    property bool   hasThreads: true        // Slack has threads; Discord doesn't
    property string currentWorkspace: ""    // teamID being viewed
    readonly property string currentWorkspaceName: {
        for (let i = 0; i < workspaces.length; i++)
            if (workspaces[i].id === currentWorkspace) return workspaces[i].name
        return ""
    }

    ListModel { id: channelsModel }
    ListModel { id: messagesModel }
    ListModel { id: threadModel }
    property alias thread: threadModel
    property var _store: ({})
    property var _threads: ({})

    // Custom emoji. _emojiByWs: teamID -> {name: file://path} (scopes the
    // picker). _emoji: merged across workspaces, for rendering :name: in
    // messages (richify has no per-message workspace context — best effort).
    property var _emoji: ({})
    property var _emojiByWs: ({})
    property int emojiGen: 0
    // Standard emoji ":name:" -> unicode (slkd's codemap.json), for the picker.
    property var _codemap: ({})
    // teamID -> [{id,name}] for @-mention autocomplete.
    property var _usersByWs: ({})

    // --- reactions ---
    function react(channelId, ts, name, remove) {
        safeWrite(JSON.stringify({ type: "react", channel: channelId, ts: ts, emoji: name, remove: !!remove }) + "\n")
    }
    // Reacting with an emoji you already used removes it (toggle), else adds.
    function toggleReaction(msg, name) {
        if (!msg || !name) return
        let mine = false
        try {
            const rx = JSON.parse(msg.reactionsJson || "[]")
            for (let i = 0; i < rx.length; i++) if (rx[i].name === name && rx[i].mine) { mine = true; break }
        } catch (e) {}
        react(currentChannelId, msg.ts, name, mine)
    }
    // file:// path for a custom emoji by name (empty for standard/unknown) —
    // used to render reaction-row icons in the react picker.
    function emojiPath(name) { return (_emoji && _emoji[name]) || "" }

    // Who-reacted, fetched on demand (Discord sends no reactor list at all; Slack
    // truncates it). ts -> { emojiName: [displayNames] }.
    property var _reactors: ({})
    signal reactorsReady(string ts)
    function reactorsFor(ts, name) {
        const m = _reactors[ts]
        return (m && m[name]) ? m[name] : []
    }
    function fetchReactors(msg) {
        if (!msg || !msg.ts) return
        let emojis = []
        try {
            const rx = JSON.parse(msg.reactionsJson || "[]")
            for (let i = 0; i < rx.length; i++) emojis.push({ name: rx[i].name, eid: rx[i].eid || "" })
        } catch (e) {}
        if (!emojis.length) return
        safeWrite(JSON.stringify({ type: "reactors", channel: currentChannelId, ts: msg.ts, emojis: emojis }) + "\n")
    }
    function applyReactors(ts, reactions) {
        const byName = {}
        const rs = reactions || []
        for (let i = 0; i < rs.length; i++) byName[rs[i].name] = rs[i].users || []
        const m = _reactors; m[ts] = byName; _reactors = m
        reactorsReady(ts)
    }
    // Unfollow a thread from the Threads view: tell slkd, and drop it locally
    // for instant feedback (the daemon re-pushes the authoritative list too).
    function unsubThread(channel, ts) {
        safeWrite(JSON.stringify({ type: "unsubThread", channel: channel, thread: ts }) + "\n")
        const out = (subThreads || []).slice()
        for (let i = 0; i < out.length; i++)
            if (out[i].channel === channel && out[i].ts === ts) { out.splice(i, 1); subThreads = out; break }
    }
    // slkd's authoritative reaction set for a message (after slk persists it).
    function applyReaction(channelId, ts, reactionsJson) {
        const arr = _store[channelId]
        if (arr) for (let i = 0; i < arr.length; i++) if (arr[i].ts === ts) { arr[i].reactionsJson = reactionsJson; break }
        if (channelId === currentChannelId)
            for (let i = 0; i < messagesModel.count; i++)
                if (messagesModel.get(i).ts === ts) { messagesModel.setProperty(i, "reactionsJson", reactionsJson); break }
        for (let i = 0; i < threadModel.count; i++)
            if (threadModel.get(i).ts === ts) { threadModel.setProperty(i, "reactionsJson", reactionsJson); break }
    }
    // Background-fetched inline images arrived — swap the placeholders in.
    function applyImages(channelId, ts, imagesJson) {
        const arr = _store[channelId]
        if (arr) for (let i = 0; i < arr.length; i++) if (arr[i].ts === ts) { arr[i].imagesJson = imagesJson; break }
        if (channelId === currentChannelId)
            for (let i = 0; i < messagesModel.count; i++)
                if (messagesModel.get(i).ts === ts) { messagesModel.setProperty(i, "imagesJson", imagesJson); break }
        for (let i = 0; i < threadModel.count; i++)
            if (threadModel.get(i).ts === ts) { threadModel.setProperty(i, "imagesJson", imagesJson); break }
    }

    // Emoji search for the picker: returns {name, custom, path, glyph}. Custom
    // (workspace) emoji first, then standard. Empty query returns a sample.
    // Relevance rank for a candidate name against the query: lower is better.
    // exact (0) > prefix (1) > word-boundary, after _/-/space (2) > substring (3);
    // -1 = no match. This is what puts ":heart:" above ":anthropic-heart:".
    function _emojiRank(name, q) {
        const i = name.indexOf(q)
        if (i < 0) return -1
        if (name === q) return 0
        if (i === 0) return 1
        const prev = name[i - 1]
        return (prev === "_" || prev === "-" || prev === " ") ? 2 : 3
    }
    function searchEmoji(q, limit) {
        q = (q || "").toLowerCase()
        const cust = _emojiByWs[currentWorkspace] || ({})   // only this workspace's customs
        if (!q) {
            const out = []
            for (const name in cust) { out.push({ name: name, custom: true, path: cust[name], glyph: "" }); if (out.length >= limit) return out }
            for (const key in _codemap) { out.push({ name: key.slice(1, -1), custom: false, path: "", glyph: _codemap[key] }); if (out.length >= limit) return out }
            return out
        }
        // Score every match across customs + standard, then sort — can't bail early
        // or the best match (often a standard emoji) gets cut by the limit.
        const scored = []
        for (const name in cust) {
            const r = _emojiRank(name, q)
            if (r >= 0) scored.push({ r: r, name: name, custom: true, path: cust[name], glyph: "" })
        }
        for (const key in _codemap) {
            const name = key.slice(1, -1)
            const r = _emojiRank(name, q)
            if (r >= 0) scored.push({ r: r, name: name, custom: false, path: "", glyph: _codemap[key] })
        }
        scored.sort(function(a, b) {
            if (a.r !== b.r) return a.r - b.r
            if (a.name.length !== b.name.length) return a.name.length - b.name.length
            if (a.custom !== b.custom) return a.custom ? -1 : 1   // workspace customs win ties
            return a.name < b.name ? -1 : 1
        })
        const out = []
        for (let i = 0; i < scored.length && out.length < limit; i++) {
            const s = scored[i]
            out.push({ name: s.name, custom: s.custom, path: s.path, glyph: s.glyph })
        }
        return out
    }
    // @-mention search over the current workspace's users.
    function searchUsers(q, limit) {
        q = (q || "").toLowerCase()
        const us = _usersByWs[currentWorkspace] || []
        const out = []
        for (let i = 0; i < us.length; i++) {
            if (!q || us[i].name.toLowerCase().indexOf(q) >= 0) out.push(us[i])
            if (out.length >= limit) break
        }
        return out
    }

    // Convert a message's markdown-ish text to RichText: escape HTML, apply
    // **bold**/~~strike~~/`code`, swap :custom_emoji: for inline <img>, and
    // map newlines. One conversion point for both snapshot and live messages.
    // CSS #rrggbb for a Theme color, so richify's inline HTML stays themeable
    // (and re-runs on theme toggle, since it reads the Theme color properties).
    function cssHex(c) {
        // A missing Theme color must NOT throw here: richify runs cssHex on every
        // message, so one undefined color (e.g. after a theme regen drops a custom
        // property) would blank EVERY message body. Degrade to a safe colour instead.
        if (!c || c.r === undefined) return "#888888"
        return "#" + [c.r, c.g, c.b].map(function (x) { return Math.round(x * 255).toString(16).padStart(2, "0") }).join("")
    }
    // A message with nothing but emoji renders large ("jumbo"), like Slack/Discord.
    function isEmojiOnly(text) {
        if (!text) return false
        let s = text.trim()
        if (!s) return false
        s = s.replace(/<a?:\w+:\d+>/g, "").replace(/:[a-z0-9_+'\-]+:/g, "").trim()
        if (s.length === 0) return true          // only custom emoji
        if (/[0-9A-Za-z]/.test(s)) return false  // has real text
        if (!/[^\x00-\x7f]/.test(s)) return false  // needs a non-ASCII (emoji) char
        return Array.from(s).length <= 6
    }
    // Language-agnostic syntax coloring for fenced code blocks: comments, strings,
    // numbers, then a common keyword set. No real parser — one master regex whose
    // alternation order lets a string/comment swallow any keywords inside it, so we
    // never recolour tokens within them. Input is already HTML-escaped (& < > are
    // entities; quotes survive literally, which the string rules rely on).
    readonly property string _codeKw: "abstract|and|as|async|await|bool|boolean|break|case|catch|char|class|const|continue|def|default|del|do|double|elif|else|end|enum|export|extends|false|final|finally|float|fn|for|from|func|function|global|go|if|impl|implements|import|in|int|interface|is|lambda|let|match|mut|new|nil|none|not|null|or|package|pass|private|protected|pub|public|raise|return|self|static|str|string|struct|super|switch|then|this|throw|trait|true|try|type|typeof|undefined|union|unless|use|val|var|void|when|while|with|yield"
    function _highlightCode(c) {
        const re = new RegExp(
            "(//[^\\n]*|#[^\\n]*|/\\*[\\s\\S]*?\\*/)"
            + "|(\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`)"
            + "|(\\b\\d+(?:\\.\\d+)?\\b)"
            + "|(\\b(?:" + _codeKw + ")\\b)", "g")
        return c.replace(re, function (m, cmt, str, num) {
            const col = cmt ? Theme.fg_muted : str ? Theme.green : num ? Theme.orange : Theme.sky
            return '<font color="' + cssHex(col) + '">' + m + '</font>'
        })
    }
    function richify(text, emojiPx) {
        const _ = emojiGen   // re-evaluate when emoji map loads
        if (!text) return ""
        const ep = emojiPx || 22
        let s = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        // Fenced code blocks (```): lift them out (with an optional language hint on
        // the fence line) so the mrkdwn / emoji / quote passes below leave their
        // contents literal; restored as a filled block just before return. Sentinels
        // are private-use chars so nothing downstream matches them.
        const codeBlocks = []
        const cb0 = String.fromCharCode(0xE005), cb1 = String.fromCharCode(0xE006)
        s = s.replace(/```(?:([a-zA-Z0-9+_#.-]+)\n)?([\s\S]*?)```/g, function (m, lang, code) {
            codeBlocks.push({ lang: (lang || "").toLowerCase(), code: code.replace(/^\n/, "").replace(/\n+$/, "") })
            return cb0 + (codeBlocks.length - 1) + cb1
        })
        // Bare URLs → styled, clickable links. Done before the emoji <img> tags
        // exist so their CDN src URLs aren't themselves linkified. Trailing
        // sentence punctuation is kept out of the link.
        s = s.replace(/(https?:\/\/[^\s<]+?)([.,;:!?)]*)(?=\s|$)/g,
            '<a href="$1"><font color="' + cssHex(Theme.sky) + '"><u>$1</u></font></a>$2')
        // mention markers from slkd (private-use runes survive the escape above):
        // … = a mention of you / @here|channel (highlighted background),
        // … = any other @user / #channel / @group (accent color).
        s = s.replace(/\ue001([^\ue002]*)\ue002/g, '<span style="background-color:' + cssHex(Theme.warning) + '; color:' + cssHex(Theme.yellow) + '">$1</span>')
        s = s.replace(/\ue000([^\ue002]*)\ue002/g, '<font color="' + cssHex(Theme.sky) + '">$1</font>')
        s = s.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>")
        s = s.replace(/~~([^~\n]+)~~/g, "<s>$1</s>")
        s = s.replace(/`([^`\n]+)`/g, '<code>$1</code>')
        // Discord custom emoji <:name:id> / <a:name:id> (escaped to &lt;…&gt;
        // above) → inline CDN image. The id alone yields the URL.
        s = s.replace(/&lt;(a?):(\w+):(\d+)&gt;/g, (m, anim, name, id) =>
            '<img src="https://cdn.discordapp.com/emojis/' + id + (anim ? '.gif' : '.png') + '?size=128" width="' + ep + '" height="' + ep + '">')
        s = s.replace(/:([a-z0-9_+'\-]+):/g, (m, name) => {
            const p = _emoji[name]
            return p ? '<img src="' + p + '" width="' + ep + '" height="' + ep + '">' : m
        })
        // Blockquotes: a leading "> " (escaped to "&gt; ") → muted text with a bar.
        s = s.replace(/(^|\n)&gt;[ \t]?([^\n]*)/g, '$1<font color="' + cssHex(Theme.fg_muted) + '">▎&#160;$2</font>')
        // Markdown bullets ("- "/"* " at line start) → • (Slack rich_text already emits •).
        s = s.replace(/(^|\n)[*-][ \t]+/g, '$1• ')
        s = s.replace(/\n/g, "<br>")
        // Restore fenced code blocks as a filled monospace block.
        s = s.replace(new RegExp(cb0 + "(\\d+)" + cb1, "g"), function (m, i) {
            const blk = codeBlocks[+i]
            const body = _highlightCode(blk.code).replace(/\n/g, "<br>")
            const label = blk.lang
                ? '<font color="' + cssHex(Theme.fg_muted) + '">' + blk.lang + '</font><br>'
                : ''
            return '<table width="100%" cellpadding="6" bgcolor="' + cssHex(Theme.overlay)
                + '"><tr><td>' + label + body + '</td></tr></table>'
        })
        return s
    }
    // Split an emoji-only message into render tokens — custom emoji as image srcs
    // (the delegate draws them as real Image elements, which antialias when scaled;
    // inline rich-text <img> uses nearest-neighbour and looks jagged), the rest as
    // glyph runs (unicode emoji render fine via the font).
    function emojiParts(text) {
        const _ = emojiGen
        const out = []
        const s = text || ""
        const re = /<(a?):(\w+):(\d+)>|:([a-z0-9_+'\-]+):/g
        let last = 0, m
        function glyph(t) { t = (t || "").trim(); if (t) out.push({ glyph: t }) }
        while ((m = re.exec(s)) !== null) {
            glyph(s.slice(last, m.index))
            if (m[3]) out.push({ img: "https://cdn.discordapp.com/emojis/" + m[3] + (m[1] === "a" ? ".gif" : ".png") + "?size=128" })
            else { const p = _emoji[m[4]]; p ? out.push({ img: p }) : out.push({ glyph: m[0] }) }
            last = re.lastIndex
        }
        glyph(s.slice(last))
        return out
    }
    property bool   threadOpen: false
    property string threadParentTs: ""
    property bool   threadOpenToLatest: false  // true when opened to catch up replies (land at bottom)
    property string threadTitle: ""
    property bool   threadsView: false   // the dedicated Threads page is showing
    function showThreadsView() { threadsView = true; safeWrite(JSON.stringify({ type: "refreshThreads" }) + "\n") }
    function hideThreadsView() { threadsView = false }

    // slkd pushes the workspace list first, then the channels.
    function setWorkspaces(list, rail, threads) {
        workspaces = list || []
        useRail = !!rail
        hasThreads = (threads === undefined) ? true : !!threads
        if (currentWorkspace === "" && workspaces.length > 0)
            currentWorkspace = workspaces[0].id
    }

    // slkd pushes this on (re)connect: every workspace's channels + threads.
    function setChannels(channels, subs) {
        subThreads = subs || []
        const firstLoad = currentChannelId === ""
        // Preserve live unread + mention across reconnects, keyed by channel id.
        const prevUnread = {}, prevMention = {}
        for (let i = 0; i < _chanList.length; i++) {
            prevUnread[_chanList[i].id] = _chanList[i].unread
            prevMention[_chanList[i].id] = _chanList[i].mention
        }
        _chanList = (channels || []).map((c, i) => ({
            id: c.id, name: c.name, kind: c.kind, topic: c.topic, avatar: c.avatar || "",
            workspace: c.workspace,
            unread: firstLoad ? (c.unread || 0)
                  : (prevUnread[c.id] !== undefined ? prevUnread[c.id] : (c.unread || 0)),
            mention: firstLoad ? (c.mention || false)
                   : (prevMention[c.id] !== undefined ? prevMention[c.id] : (c.mention || false)),
            ord: i
        }))
        rebuildChannelModel()
        if (firstLoad) selectFirstInWorkspace()
    }

    function selectFirstInWorkspace() {
        for (let i = 0; i < _chanList.length; i++)
            if (_chanList[i].workspace === currentWorkspace) {
                selectChannel(_chanList[i].id, _chanList[i].name, _chanList[i].topic)
                return
            }
    }
    function switchWorkspace(teamID) {
        if (!teamID || teamID === currentWorkspace) return
        currentWorkspace = teamID
        rebuildChannelModel()
        selectFirstInWorkspace()
    }
    function cycleWorkspace(dir) {
        if (workspaces.length < 2) return
        let idx = 0
        for (let i = 0; i < workspaces.length; i++) if (workspaces[i].id === currentWorkspace) idx = i
        switchWorkspace(workspaces[(idx + dir + workspaces.length) % workspaces.length].id)
    }

    // Sidebar source of truth, kept sorted so section grouping re-flows live.
    property var _chanList: []
    // Unread DMs and channel @-mentions get a priority section at the very top
    // (under the Threads row); other unread sits below in "Unread".
    function sectionOf(unread, kind, mention) {
        if (unread > 0 && mention) return "Mentions & DMs"
        if (unread > 0) return "Unread"
        return kind === "dm" ? "Direct messages" : "Channels"
    }
    function rebuildChannelModel() {
        const rank = { "Mentions & DMs": 0, "Unread": 1, "Channels": 2, "Direct messages": 3 }
        // Only the current workspace's channels are visible at a time.
        const sorted = _chanList.filter(c => c.workspace === currentWorkspace).sort((a, b) => {
            const ra = rank[sectionOf(a.unread, a.kind, a.mention)], rb = rank[sectionOf(b.unread, b.kind, b.mention)]
            return ra !== rb ? ra - rb : a.ord - b.ord
        })
        channelsModel.clear()
        for (let i = 0; i < sorted.length; i++) {
            const c = sorted[i]
            channelsModel.append({ id: c.id, name: c.name, kind: c.kind, topic: c.topic,
                                   unread: c.unread, mention: c.mention, avatar: c.avatar || "",
                                   workspace: c.workspace, section: sectionOf(c.unread, c.kind, c.mention) })
        }
    }
    // Update a channel's unread + mention (by id); re-flow sections only if it
    // crossed a section boundary. count===0 clears the mention flag (read).
    function applyUnread(id, count, mention) {
        const e = _chanList.find(c => c.id === id)
        if (!e) return
        const before = sectionOf(e.unread, e.kind, e.mention)
        e.unread = Math.min(count, 99)
        e.mention = count === 0 ? false : !!mention
        if (e.workspace !== currentWorkspace) return
        if (sectionOf(e.unread, e.kind, e.mention) !== before) { rebuildChannelModel(); return }
        for (let i = 0; i < channelsModel.count; i++)
            if (channelsModel.get(i).id === id) {
                channelsModel.setProperty(i, "unread", e.unread)
                channelsModel.setProperty(i, "mention", e.mention)
                return
            }
    }

    function selectChannel(id, name, topic) {
        threadsView = false   // opening a channel leaves the Threads page
        viewingNonMember = false   // a normal channel open clears any preview state
        currentChannelId = id
        currentChannel = name
        currentTopic = topic
        loadingOlder = false
        _noMore[id] = false
        messagesModel.clear()        // slkd replies `recent` → loadRecent populates
        safeWrite(JSON.stringify({ type: "recent", channel: id }) + "\n")
        applyUnread(id, 0)   // clear locally (and re-flow sections)
        sendFocus()          // slkd suppresses notifications for the channel we're on
    }

    // slkd streams a channel's history in small batches (reset on the first,
    // final on the last) — one big line overruns the Socket parse buffer.
    // Reply-context fields exist only on Discord messages; default them so the
    // delegate's required roles are present for Slack too (and the role gets
    // registered on the first append).
    // Group a message under the previous one only if it's the same author AND
    // within 10 minutes — a longer gap shows the full avatar+name header again.
    function _grp(prev, cur) {
        return !!prev && !!cur && prev.author === cur.author
               && (parseFloat(cur.ts) - parseFloat(prev.ts)) < 600
    }
    function normMsg(m) {
        if (m.replyAuthor === undefined) m.replyAuthor = ""
        if (m.replyText === undefined) m.replyText = ""
        if (m.replyToTs === undefined) m.replyToTs = ""
        if (m.mine === undefined) m.mine = false
        if (m.day === undefined) m.day = m.ts ? dayKeyOf(m.ts) : ""
        if (m.subtype === undefined) m.subtype = ""
        if (m.thread_ts === undefined) m.thread_ts = ""
        if (m.channelRef === undefined) m.channelRef = ""
        if (m.pending === undefined) m.pending = false
        return m
    }
    // ctrl+e in insert mode: the last message you sent, scoped to the panel.
    function lastMineInChannel() {
        const a = _store[currentChannelId] || []
        for (let i = a.length - 1; i >= 0; i--) if (a[i].mine) return a[i]
        return null
    }
    function lastMineInThread() {
        for (let i = threadModel.count - 1; i >= 0; i--) { const m = threadModel.get(i); if (m.mine) return m }
        return null
    }
    // Date grouping for the message list: a stable YYYYMMDD key per message, and
    // a friendly label (Today/Yesterday/weekday) for the section divider.
    function _dk(d) {
        const mo = d.getMonth() + 1, da = d.getDate()
        return "" + d.getFullYear() + (mo < 10 ? "0" : "") + mo + (da < 10 ? "0" : "") + da
    }
    function dayKeyOf(ts) { return _dk(new Date(parseFloat(ts) * 1000)) }
    function dayLabel(key) {
        const now = new Date()
        if (key === _dk(now)) return "Today"
        if (key === _dk(new Date(now.getTime() - 86400000))) return "Yesterday"
        const d = new Date(parseInt(key.substr(0, 4)), parseInt(key.substr(4, 2)) - 1, parseInt(key.substr(6, 2)))
        return Qt.formatDate(d, "dddd, MMM d")
    }
    function loadRecent(id, msgs, reset, isFinal, jump) {
        msgs = msgs || []
        if (reset) {
            _store[id] = []
            _noMore[id] = false
            if (id === currentChannelId) messagesModel.clear()
        }
        if (!_store[id]) _store[id] = []
        const arr = _store[id]
        for (let i = 0; i < msgs.length; i++) {
            normMsg(msgs[i])
            msgs[i].grouped = arr.length > 0 && _grp(arr[arr.length - 1], msgs[i])
            arr.push(msgs[i])
            if (id === currentChannelId) messagesModel.append(msgs[i])
        }
        // Mark read on the SERVER once the last batch lands (latest ts known),
        // so it doesn't resurface as unread elsewhere.
        if (isFinal && id === currentChannelId && arr.length > 0 && arr[arr.length - 1].ts)
            safeWrite(JSON.stringify({ type: "markread", channel: id, before: arr[arr.length - 1].ts }) + "\n")
        // A jump fetch (permalink) carries the target ts — scroll to + flash it
        // once its window is fully loaded.
        if (isFinal && jump && id === currentChannelId)
            jumpToMessage(jump)
    }

    // Emitted when a jumped-to message's window has loaded; the MessageList
    // scrolls to and flashes it.
    signal jumpToMessage(string ts)

    // Link click router: a Slack message permalink
    // (…/archives/<CID>/p<ts>[?thread_ts=…]) opens in-client; everything else
    // goes to the browser. p<digits> → ts with the last 6 digits as microseconds.
    property string _pendingJumpUrl: ""    // browser fallback if a jump fetch fails
    property string _pendingJumpTeam: ""   // team subdomain of a permalink jump (for Join)
    property bool viewingNonMember: false  // previewing a channel we haven't joined
    property string _nonMemberChannel: ""
    property string _nonMemberName: ""
    function joinCurrent() {
        if (_nonMemberChannel === "") return
        safeWrite(JSON.stringify({ type: "join", channel: _nonMemberChannel, text: _nonMemberName, team: _pendingJumpTeam }) + "\n")
        viewingNonMember = false   // daemon will re-sync the sidebar and open it as a member
    }

    function openUrl(url) {
        const m = (url || "").match(/\/archives\/([A-Z0-9]+)\/p(\d+)/)
        console.log("DBG2 openUrl url=" + url + " match=" + (m ? "yes" : "no") + " sockConn=" + sock.connected)
        if (m && m[2].length > 6) {
            const ts = m[2].slice(0, -6) + "." + m[2].slice(-6)
            const tm = url.match(/[?&]thread_ts=([0-9.]+)/)
            const sub = (url.match(/https?:\/\/([a-z0-9-]+)\.slack\.com/) || [])[1] || ""
            if (openPermalink(m[1], ts, tm ? tm[1] : "", sub, url)) return
        }
        Qt.openUrlExternally(url)
    }

    // Open a Slack message permalink in-client: switch to its workspace/channel
    // and jump to the message. Returns false if the channel isn't known here
    // (caller then falls back to the browser). threadTs opens the thread.
    function openPermalink(channelId, ts, threadTs, sub, url) {
        const ch = _findChannel(channelId)
        console.log("DBG2 openPermalink ch=" + (ch ? ch.name : "NULL") + " sub=" + sub + " ts=" + ts)
        if (!ch && !sub) return false   // not joined and no team to route by → browser
        if (threadOpen) closeThread()
        _pendingJumpUrl = url || ""
        _pendingJumpTeam = sub || ""
        if (ch) {
            // A channel we're in: switch to it now and request the jump window.
            if (ch.workspace && ch.workspace !== currentWorkspace) {
                currentWorkspace = ch.workspace
                rebuildChannelModel()
            }
            threadsView = false
            currentChannelId = channelId
            currentChannel = ch.name
            currentTopic = ch.topic || ""
            loadingOlder = false
            _noMore[channelId] = false
            messagesModel.clear()
            applyUnread(channelId, 0)
            sendFocus()
            if (threadTs) {
                threadOpenToLatest = true
                threadParentTs = threadTs
                threadTitle = ""
                threadModel.clear()
                threadOpen = true
                safeWrite(JSON.stringify({ type: "replies", channel: channelId, thread: threadTs }) + "\n")
            }
        }
        // For a non-joined channel we don't switch the view yet — the daemon's
        // jump response adopts it (or jumpFailed falls back to the browser).
        safeWrite(JSON.stringify({ type: "jump", channel: channelId, ts: ts, team: sub || "" }) + "\n")
        return true
    }

    signal prepended(int n)
    signal aboutToPrepend()   // fired right before older rows insert, so the view can anchor
    property bool loadingOlder: false
    property var _noMore: ({})

    // @-mentions picked from the composer autocomplete: "@Display Name" -> user id.
    // Converted to Slack's <@id> wire form on send (TextArea holds plain text).
    property var _mentionMap: ({})
    function registerMention(display, id) { const m = _mentionMap; m["@" + display] = id; _mentionMap = m }
    function resolveMentions(text) {
        let t = text
        for (const key in _mentionMap)
            if (t.indexOf(key) >= 0) t = t.split(key).join("<@" + _mentionMap[key] + ">")
        return t
    }

    // Staged attachment: Ctrl+V uploads a clipboard image but does NOT send —
    // it shows in the composer and goes out with the next message (on Enter).
    property string attachState: "none"   // "none" | "uploading" | "ready"
    property string attachName: ""
    property bool _awaitingPaste: false   // Ctrl+V sent; awaiting the daemon's image-or-text verdict
    property string _pendingImagePath: "" // local file:// of a staged paste image (for optimistic preview)
    function pasteImage(thread) {
        if (!currentChannelId) return
        _awaitingPaste = true
        safeWrite(JSON.stringify({ type: "uploadClipboard", channel: currentChannelId, thread: thread || "" }) + "\n")
    }
    function dropAttach() {
        if (attachState === "none") return
        attachState = "none"; attachName = ""
        safeWrite(JSON.stringify({ type: "dropAttach", channel: currentChannelId }) + "\n")
    }
    function clearAttach() { attachState = "none"; attachName = ""; _awaitingPaste = false; _pendingImagePath = "" }
    // Clipboard held no image → the focused input should paste text instead.
    signal pasteFallback()

    // --- optimistic send: show your message instantly, reconcile with the echo ---
    property var _selfProfile: null   // {author,initials,color,avatar} learned from your own messages
    property int _optSeq: 0
    function _insertOptimistic(id, text, imagesJson) {
        if (id !== currentChannelId) return
        const p = _selfProfile || {}
        const now = new Date()
        const arr = _store[id] || (_store[id] = [])
        const last = arr.length ? arr[arr.length - 1] : null
        const m = normMsg({
            ts: "opt-" + (++_optSeq), user: "", mine: true, pending: true,
            author: p.author || "You", initials: p.initials || "·",
            color: p.color || "#9aa0a6", avatar: p.avatar || "",
            time: Qt.formatDateTime(now, "HH:mm"), text: text,
            reactionsJson: "[]", imagesJson: imagesJson || "[]", replyAuthor: "", replyText: "",
            subtype: "", reply_count: 0, thread_ts: "", channelRef: "",
            // Real (today) day key — matches the echo, so reconcile never changes
            // the section. (Faking the previous message's day scrambled the dividers.)
            day: _dk(now)
        })
        m.grouped = last ? _grp(last, m) : false
        arr.push(m)
        messagesModel.append(m)
        reflowList()
    }
    // The server echoed one of our messages → swap it into its optimistic slot
    // (oldest pending with matching text; echoes arrive in send order).
    function _reconcileOptimistic(id, msg) {
        const arr = _store[id]
        if (!arr) return false
        for (let i = 0; i < arr.length; i++) {
            if (arr[i].pending && arr[i].mine) {   // FIFO: echoes arrive in send order; text-match broke on mentions/rendering
                const optTs = arr[i].ts
                msg.pending = false; msg.grouped = arr[i].grouped
                arr[i] = msg
                if (id === currentChannelId) {
                    for (let j = 0; j < messagesModel.count; j++)
                        if (messagesModel.get(j).ts === optTs) { messagesModel.set(j, msg); break }
                    reflowList()   // swapped an item in place → re-flow so date dividers don't go stale
                }
                return true
            }
        }
        return false
    }

    // Transient status toast (e.g. "Copied"); the shell renders it and fades out.
    signal toast(string message)

    // --- message actions (edit / delete / copy) ---
    function editMessage(ts, text) {
        const t = (text || "").trim()
        if (!ts || t.length === 0) return
        safeWrite(JSON.stringify({ type: "edit", channel: currentChannelId, ts: ts, text: resolveMentions(t) }) + "\n")
    }
    function deleteMessage(msg) {
        if (msg && msg.ts) safeWrite(JSON.stringify({ type: "delete", channel: currentChannelId, ts: msg.ts }) + "\n")
    }
    // strip mention markers + the @… leading markdown so copied text is clean
    function plainText(s) { return (s || "").replace(/[\ue000\ue001\ue002]/g, "") }
    function copyText(msg) {
        if (!msg) return
        const t = plainText(msg.text)
        if (t.length) { Quickshell.execDetached(["wl-copy", "--", t]); toast("Copied message") }
    }
    // A deleted message (echoed back over the websocket) — drop it everywhere.
    function applyDelete(channelId, ts) {
        const arr = _store[channelId]
        if (arr) for (let i = 0; i < arr.length; i++) if (arr[i].ts === ts) { arr.splice(i, 1); break }
        if (channelId === currentChannelId)
            for (let i = 0; i < messagesModel.count; i++)
                if (messagesModel.get(i).ts === ts) { messagesModel.remove(i); break }
        for (let i = 0; i < threadModel.count; i++)
            if (threadModel.get(i).ts === ts) { threadModel.remove(i); break }
    }

    // --- browse / join public channels ---
    property var browseResults: []       // [{id,name,member}]
    signal browseLoaded()
    function requestBrowse() { safeWrite(JSON.stringify({ type: "browse", workspace: currentWorkspace }) + "\n") }
    function joinChannel(id, name) { safeWrite(JSON.stringify({ type: "join", workspace: currentWorkspace, channel: id, text: name }) + "\n") }

    signal sentMessage()   // chat should jump to the bottom to show it
    signal reflowList()    // optimistic in-place update → MessageList re-flows so date dividers don't go stale
    // Tell the server we're typing so others see the indicator — throttled, since
    // the server-side indicator lasts ~10s (re-send while still typing).
    property real _lastTyping: 0
    function notifyTyping() {
        if (!currentChannelId) return
        const now = Date.now()
        if (now - _lastTyping < 8000) return
        _lastTyping = now
        safeWrite(JSON.stringify({ type: "typing", channel: currentChannelId }) + "\n")
    }
    function sendMessage(text) {
        const t = (text || "").trim()
        if (t.length === 0 && attachState === "none") return   // allow attachment-only sends
        // Real send: slkd → Client.SendMessage. Slack echoes it back, so it
        // lands via ingest() like any other message. A staged attachment (if any)
        // is held per-channel by the daemon and goes out with this send.
        const sent = resolveMentions(t)
        // A staged paste image → preview it inline (dimmed) from its local file.
        let imgs = ""
        if (attachState !== "none" && _pendingImagePath) {
            const gif = _pendingImagePath.toLowerCase().indexOf(".gif") !== -1
            imgs = JSON.stringify([{ type: gif ? "gif" : "img", path: _pendingImagePath, w: 0, h: 0 }])
        }
        safeWrite(JSON.stringify({ type: "send", channel: currentChannelId, text: sent }) + "\n")
        // Show it immediately (text and/or image); the echo reconciles it in place.
        if (imgs || t.length > 0) _insertOptimistic(currentChannelId, t, imgs)   // typed text, not resolved markup → clean mention placeholder
        clearAttach()
        sentMessage()
    }

    // Reply to a specific message. The daemon maps `thread` → a Discord reply
    // reference (or a Slack thread reply).
    function sendReplyTo(ts, text) {
        const t = (text || "").trim()
        if ((t.length === 0 && attachState === "none") || !ts) return
        safeWrite(JSON.stringify({ type: "send", channel: currentChannelId, text: resolveMentions(t), thread: ts }) + "\n")
        clearAttach()
        sentMessage()
    }

    // Ask slkd for older history when the user scrolls to the top.
    function requestOlder() {
        if (loadingOlder || _noMore[currentChannelId]) return
        const arr = _store[currentChannelId]
        if (!arr || arr.length === 0 || !arr[0].ts) return
        loadingOlder = true
        loadingTimer.restart()
        safeWrite(JSON.stringify({ type: "history", channel: currentChannelId, before: arr[0].ts }) + "\n")
    }
    function prependOlder(id, msgs) {
        loadingOlder = false
        const arr = _store[id] || []
        const oldest = arr.length > 0 ? arr[0].ts : "9999999999"
        msgs = (msgs || []).filter(m => m.ts < oldest)   // drop any boundary overlap
        if (msgs.length === 0) { _noMore[id] = true; return }
        for (let i = 0; i < msgs.length; i++) { normMsg(msgs[i]); msgs[i].grouped = i > 0 && _grp(msgs[i - 1], msgs[i]) }
        _store[id] = msgs.concat(arr)
        if (id === currentChannelId) {
            aboutToPrepend()
            for (let i = 0; i < msgs.length; i++) messagesModel.insert(i, msgs[i])
            prepended(msgs.length)
        }
    }
    Timer { id: loadingTimer; interval: 5000; onTriggered: backend.loadingOlder = false }

    // Wall-clock of the last event from slkd (incl. heartbeat pings). Drives
    // dead-socket detection — Quickshell's sock.connected stays stuck-true after
    // a server-side close, so we can't rely on it.
    property double lastRecv: 0

    // --- live stream from slkd (real Slack events over a Unix socket) ---
    function onEvent(line) {
        if (!line) return
        lastRecv = Date.now()
        let e
        try { e = JSON.parse(line) } catch (x) { return }
        if (e.type === "ping") return
        if (e.type === "message") ingest(e.channel, e.msg, e.thread, e.mention)
        else if (e.type === "replyCountInc") bumpReplyCount(e.channel, e.ts)
        else if (e.type === "workspaces") setWorkspaces(e.workspaces, e.rail, e.threads)
        else if (e.type === "updateAvailable") { updateCurrent = e.current || ""; updateLatest = e.latest || ""; updateAvailable = true }
        else if (e.type === "users") { _usersByWs = e.users || ({}) }
        else if (e.type === "reaction") applyReaction(e.channel, e.ts, e.reactionsJson)
        else if (e.type === "images") applyImages(e.channel, e.ts, e.imagesJson)
        else if (e.type === "delete") applyDelete(e.channel, e.ts)
        else if (e.type === "browse") { browseResults = e.channels || []; browseLoaded() }
        else if (e.type === "channels") setChannels(e.channels, e.subThreads)
        else if (e.type === "recent") {
            // A jump into a channel we haven't joined: adopt it now that its
            // window has arrived (the view wasn't switched up front).
            if (e.jump && e.channel !== currentChannelId && _findChannel(e.channel) === null) {
                threadsView = false
                currentChannelId = e.channel
                currentChannel = e.channelName ? ("#" + e.channelName) : e.channel
                currentTopic = ""
                loadingOlder = false
                _noMore[e.channel] = false
                messagesModel.clear()
                sendFocus()
            }
            if (e.jump) {
                _pendingJumpUrl = ""   // jump succeeded; no browser fallback
                viewingNonMember = (e.joined === false)
                if (viewingNonMember) { _nonMemberChannel = e.channel; _nonMemberName = e.channelName || "" }
            }
            loadRecent(e.channel, e.msgs, e.reset, e.final, e.jump)
        }
        else if (e.type === "jumpFailed") {
            // Couldn't fetch (private/no access) — open the original link instead.
            if (_pendingJumpUrl !== "") { Qt.openUrlExternally(_pendingJumpUrl); _pendingJumpUrl = "" }
        }
        else if (e.type === "history") prependOlder(e.channel, e.msgs)
        else if (e.type === "replies") setThread(e.channel, e.thread, e.msgs)
        else if (e.type === "unread") setChannelUnread(e.channel, e.count, e.mention)
        else if (e.type === "threadUnread") setThreadUnread(e.channel, e.thread, e.count)
        else if (e.type === "viewReady") openViewer(e.paths || e.path, e.mediatype)
        else if (e.type === "open") openFromNotification(e.workspace, e.channel, e.thread)
        else if (e.type === "typing") showTyping(e.channel, e.thread, e.user)
        else if (e.type === "reactors") applyReactors(e.ts, e.reactions)
        else if (e.type === "attachUploading") {
            // Daemon found a clipboard image and began uploading → show the
            // "uploading" chip now. Text pastes never reach here, so no false flash.
            _awaitingPaste = false
            attachState = "uploading"; attachName = e.name || "image"
            _pendingImagePath = e.path || ""
        }
        else if (e.type === "attachReady") {
            // Upload finished (ok) — or no image / failed. A no-image verdict while
            // still awaiting the Ctrl+V result → paste the clipboard text instead.
            if (e.ok) { attachState = "ready"; attachName = e.name || "image" }
            else if (_awaitingPaste) pasteFallback()
            else attachState = "none"
            _awaitingPaste = false
        }
    }

    // Clicking a desktop notification (routed via slkd) opens that channel,
    // switching workspace first if it lives in another one.
    function openFromNotification(workspace, id, thread) {
        const ch = _findChannel(id)
        if (!ch) return
        if (threadOpen) closeThread()
        if (workspace && workspace !== currentWorkspace) {
            currentWorkspace = workspace
            rebuildChannelModel()
        }
        selectChannel(id, ch.name, ch.topic)
        // A thread-reply notification opens that thread on top of the channel.
        if (thread) {
            threadOpenToLatest = true   // you were pinged about a reply → land at the latest
            threadParentTs = thread
            threadTitle = ""        // filled from the parent once replies arrive
            threadModel.clear()
            threadOpen = true
            _clearThreadUnread(thread)
            safeWrite(JSON.stringify({ type: "replies", channel: id, thread: thread }) + "\n")
        }
    }

    // Tell slkd what channel we're viewing so it suppresses notifications for
    // it while the window is focused (slkd tracks focus via niri's event stream).
    function sendFocus() {
        safeWrite(JSON.stringify({ type: "focus", channel: threadsView ? "" : currentChannelId }) + "\n")
    }

    // Open a focused message's first image in the custom media viewer (same
    // script the endcord fork uses). slkd downloads the full-res original,
    // then replies viewReady → we launch the script with the local path.
    function viewImage(msg) {
        if (!msg) return
        let imgs
        try { imgs = JSON.parse(msg.imagesJson || "[]") } catch (e) { return }
        if (!imgs.length || !imgs[0].full) return
        // A video opens alone (mpv). Photos open as a SET so a message with several
        // is navigable in imv. slkd downloads the full-res to a purgeable view cache
        // and replies viewReady with the local path(s).
        if (imgs[0].type === "video") {
            const v = imgs[0]
            safeWrite(JSON.stringify({ type: "view", channel: currentChannelId,
                images: [{ id: v.id, url: v.full, ext: v.ext }], mediatype: "video" }) + "\n")
            return
        }
        const items = imgs.filter(function (i) { return i.type !== "video" && i.full })
                          .map(function (i) { return { id: i.id, url: i.full, ext: i.ext } })
        if (!items.length) return
        safeWrite(JSON.stringify({ type: "view", channel: currentChannelId,
            images: items, mediatype: "img" }) + "\n")
    }
    function openViewer(paths, mediatype) {
        const arr = Array.isArray(paths) ? paths : [paths]
        // strip file://; newline-join so the script opens them all together.
        const raw = arr.map(function (p) { return p.indexOf("file://") === 0 ? p.slice(7) : p })
        Quickshell.execDetached([(Quickshell.env("SLK_MEDIA_VIEWER") || (Quickshell.env("HOME") + "/.config/endcord/media-viewer.sh")), raw.join("\n"), mediatype || "img"])
    }
    // `o` — open the focused message's link: Slack permalinks jump in-client,
    // everything else goes to the browser.
    function openLink(msg) {
        if (msg && msg.link) openUrl(msg.link)
    }
    // `o` on a message: if it mentions a #channel you're in, open that channel;
    // otherwise fall back to opening the first URL.
    function openChannelRef(msg) {
        if (msg && msg.channelRef && _findChannel(msg.channelRef)) {
            openFromNotification(currentWorkspace, msg.channelRef, "")
            return
        }
        openLink(msg)
    }
    // Authoritative unread from slkd (reflects reads made in slk too).
    function setChannelUnread(id, count, mention) { applyUnread(id, count, mention) }
    // A live thread reply bumps the parent's "N replies" count in the channel view
    // (the reply itself lands in the thread panel, not the timeline).
    function bumpReplyCount(channelId, parentTs) {
        const arr = _store[channelId]
        if (!arr) return
        for (let i = 0; i < arr.length; i++) if (arr[i].ts === parentTs) {
            arr[i].reply_count = (arr[i].reply_count || 0) + 1
            if (channelId === currentChannelId)
                for (let j = 0; j < messagesModel.count; j++)
                    if (messagesModel.get(j).ts === parentTs) { messagesModel.setProperty(j, "reply_count", arr[i].reply_count); break }
            return
        }
    }
    function ingest(id, msg, thread, mention) {
        normMsg(msg)
        if (msg.mine && msg.author)
            _selfProfile = { author: msg.author, initials: msg.initials, color: msg.color, avatar: msg.avatar }
        const isBroadcast = msg.subtype === "thread_broadcast"
        // A plain reply lives only in the thread panel. A broadcast ("also sent to
        // channel") shows in the thread AND the channel timeline, so it falls through.
        if (thread && thread !== msg.ts) {
            if (threadOpen && id === currentChannelId && thread === threadParentTs) {
                let done = false
                for (let i = 0; i < threadModel.count; i++)   // edit: replace in place
                    if (threadModel.get(i).ts === msg.ts) { msg.grouped = threadModel.get(i).grouped; threadModel.set(i, msg); done = true; break }
                if (!done) {
                    msg.grouped = threadModel.count > 0 && _grp(threadModel.get(threadModel.count - 1), msg)
                    threadModel.append(msg)
                    // we're reading this thread → mark the reply read so it doesn't
                    // resurface as unread in the Threads list (and syncs to Slack)
                    _clearThreadUnread(thread)
                    safeWrite(JSON.stringify({ type: "markThreadRead", channel: id, thread: thread, ts: msg.ts }) + "\n")
                }
            } else if (!isBroadcast) {
                bumpThreadUnread(id, thread)   // live unread on a followed thread
            }
            if (!isBroadcast) return
        }
        // edit: a message we already have (same ts) → replace in place, don't append
        if (_store[id]) {
            const a = _store[id]
            for (let i = 0; i < a.length; i++) if (a[i].ts === msg.ts) {
                msg.grouped = a[i].grouped
                a[i] = msg
                if (id === currentChannelId)
                    for (let j = 0; j < messagesModel.count; j++)
                        if (messagesModel.get(j).ts === msg.ts) { messagesModel.set(j, msg); break }
                return
            }
        }
        // A just-echoed message of ours → drop it into its optimistic placeholder.
        if (msg.mine && _reconcileOptimistic(id, msg)) return
        if (!_store[id]) _store[id] = []
        const arr = _store[id]
        msg.grouped = arr.length > 0 && _grp(arr[arr.length - 1], msg)
        arr.push(msg)
        if (id === currentChannelId) {
            messagesModel.append(msg)
            if (typing) typing = false
        } else {
            const e = _chanList.find(c => c.id === id)
            if (e) applyUnread(id, (e.unread || 0) + 1, e.mention || mention)
        }
    }

    // Threads the user follows (slk's "Threads" view) across ALL workspaces.
    property var subThreads: []
    // Only the current workspace's followed threads — what the UI shows.
    readonly property var currentSubThreads: (subThreads || []).filter(t => t.workspace === currentWorkspace)
    // Badge = number of CURRENT-workspace threads with unread replies.
    readonly property int threadUnreadTotal: {
        let n = 0
        for (let i = 0; i < currentSubThreads.length; i++) if ((currentSubThreads[i].unread || 0) > 0) n++
        return n
    }
    // Authoritative per-thread unread from slkd (reflects reads in slk too).
    function setThreadUnread(channel, ts, count) {
        const out = subThreads.slice()
        for (let i = 0; i < out.length; i++)
            if (out[i].ts === ts && out[i].channel === channel) {
                out[i] = Object.assign({}, out[i], { unread: Math.min(count, 99) })
                subThreads = out
                return
            }
    }
    // Live: a reply landed on a followed thread that isn't open — bump its
    // unread badge (reassign the array so bindings refresh).
    function bumpThreadUnread(channel, ts) {
        const out = subThreads.slice()
        for (let i = 0; i < out.length; i++)
            if (out[i].ts === ts && out[i].channel === channel) {
                out[i] = Object.assign({}, out[i], { unread: (out[i].unread || 0) + 1, last: ts })
                subThreads = out
                return
            }
    }
    // Clear a thread's unread when opened.
    function _clearThreadUnread(ts) {
        const out = subThreads.slice()
        for (let i = 0; i < out.length; i++)
            if (out[i].ts === ts && out[i].unread) { out[i] = Object.assign({}, out[i], { unread: 0 }); subThreads = out; return }
    }

    // Open a followed thread directly (its parent may not be in the channel's
    // loaded top-level messages, so seed the model from the carried parent).
    // t.channel is the channel id; t.channelName the display name.
    function openThreadFromSub(t) {
        if (!t) return
        if (t.workspace && t.workspace !== currentWorkspace) {
            currentWorkspace = t.workspace
            rebuildChannelModel()
        }
        if (t.channel !== currentChannelId) {
            const ch = _findChannel(t.channel)
            selectChannel(t.channel, ch ? ch.name : (t.channelName || ""), ch ? ch.topic : "")
        }
        threadOpenToLatest = true   // catching up replies → land at the latest
        threadParentTs = t.ts
        threadTitle = t.title
        threadModel.clear()
        if (t.parent) threadModel.append(normMsg(t.parent))
        threadOpen = true
        _clearThreadUnread(t.ts)
        safeWrite(JSON.stringify({ type: "replies", channel: t.channel, thread: t.ts }) + "\n")
    }

    // Recently opened threads (newest first), for the Ctrl+K palette.
    property var recentThreads: []
    function _pushRecentThread(channel, ts, title, preview) {
        const out = [{ channel: channel, ts: ts, title: title, preview: preview }]
        for (let i = 0; i < recentThreads.length && out.length < 8; i++) {
            const r = recentThreads[i]
            if (!(r.channel === channel && r.ts === ts)) out.push(r)
        }
        recentThreads = out
    }
    // Re-open a thread from the palette: switch channel if needed, then open.
    function reopenThread(id, ts) {
        if (id !== currentChannelId) {
            const ch = _findChannel(id)
            if (ch) selectChannel(id, ch.name, ch.topic)
        }
        const arr = _store[id] || []
        for (let i = 0; i < arr.length; i++)
            if (arr[i].ts === ts) { openThread(arr[i]); return }
    }
    function _findChannel(id) {
        const e = _chanList.find(c => c.id === id)
        return e || null
    }

    // --- threads ---
    function openThread(msg) {
        if (!msg) return
        // A broadcast/reply shown in the channel belongs to a parent thread — open
        // that, not a thread rooted at the reply itself. Prefer the parent message
        // we already have in the channel; fall back to a stub the replies fill in.
        if (msg.thread_ts && msg.thread_ts !== msg.ts) {
            const ca = _store[currentChannelId] || []
            let parent = null
            for (let i = 0; i < ca.length; i++) if (ca[i].ts === msg.thread_ts) { parent = ca[i]; break }
            msg = parent || normMsg({ author: msg.replyAuthor || msg.author || "", initials: "", color: "",
                                      avatar: "", time: msg.time, text: "", grouped: false,
                                      reactionsJson: "[]", imagesJson: "[]", ts: msg.thread_ts, reply_count: 0 })
        }
        threadOpenToLatest = false   // clicked the root in-channel → start at the parent
        threadParentTs = msg.ts
        threadTitle = msg.author
        _pushRecentThread(currentChannelId, msg.ts, msg.author, (msg.text || "").replace(/<[^>]+>/g, "").slice(0, 50))
        threadModel.clear()
        const arr = _threads[msg.ts]
        if (arr && arr.length) {
            for (let i = 0; i < arr.length; i++) threadModel.append(normMsg(arr[i]))
        } else {
            // normMsg fills replyAuthor/replyText: the first append fixes the
            // ListModel's role schema, so it MUST carry every role MessageDelegate
            // requires or the real replies (appended later) lose those roles and
            // the delegate fails to instantiate (blank thread panel).
            threadModel.append(normMsg({ author: msg.author, initials: msg.initials, color: msg.color,
                                 avatar: msg.avatar || "", time: msg.time, text: msg.text, grouped: false,
                                 reactionsJson: msg.reactionsJson || "[]", imagesJson: msg.imagesJson || "[]",
                                 ts: msg.ts, reply_count: 0 }))
        }
        threadOpen = true
        safeWrite(JSON.stringify({ type: "replies", channel: currentChannelId, thread: msg.ts }) + "\n")
        _clearThreadUnread(msg.ts)
    }
    function setThread(channel, thread, msgs) {
        if (!threadOpen || thread !== threadParentTs || !msgs || msgs.length === 0) return
        if (threadTitle === "" && msgs[0]) threadTitle = msgs[0].author   // notif path had no title
        for (let i = 0; i < msgs.length; i++) { normMsg(msgs[i]); msgs[i].grouped = i > 0 && _grp(msgs[i - 1], msgs[i]) }
        threadModel.clear()
        for (let i = 0; i < msgs.length; i++) threadModel.append(msgs[i])
        _threads[thread] = msgs
    }
    function closeThread() { threadOpen = false }
    function sendThreadReply(text, broadcast) {
        const t = (text || "").trim()
        if ((t.length === 0 && attachState === "none") || !threadParentTs) return
        safeWrite(JSON.stringify({ type: "send", channel: currentChannelId, text: resolveMentions(t), thread: threadParentTs, broadcast: !!broadcast }) + "\n")
        clearAttach()
    }
    function showTyping(id, thread, who) {
        if (!who) return
        // Typing inside a thread we have open → show it in the thread panel.
        if (thread && threadOpen && thread === threadParentTs) {
            threadTypingWho = who; threadTyping = true; threadTypingClear.restart()
            return
        }
        // Channel-level typing (no thread) for the channel we're viewing.
        if (!thread && id === currentChannelId) {
            typingWho = who; typing = true; typingClear.restart()
        }
    }
    Timer { id: typingClear; interval: 4000; onTriggered: backend.typing = false }
    Timer { id: threadTypingClear; interval: 4000; onTriggered: backend.threadTyping = false }

    readonly property string _dataDir: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/" + (Quickshell.env("SLK_SOCK") || "slqs")

    FileView {
        path: backend._dataDir + "/emoji" + (Quickshell.env("SLK_SOCK") === "dsqrd" ? "-dsqrd" : "") + ".json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const byWs = JSON.parse(text())     // { teamID: {name: path} }
                backend._emojiByWs = byWs
                const merged = {}                   // flatten for message rendering
                for (const ws in byWs) for (const n in byWs[ws]) merged[n] = byWs[ws][n]
                backend._emoji = merged
                backend.emojiGen++
            } catch (e) { console.warn("emoji.json parse failed") }
        }
    }

    FileView {
        path: backend._dataDir + "/codemap.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { backend._codemap = JSON.parse(text()) } catch (e) {} }
    }

    function safeWrite(s) {
        if (sock.connected) sock.write(s)
        else reconnect.restart()   // kick a reconnect; the user can retry
    }

    Socket {
        id: sock
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/" + (Quickshell.env("SLK_SOCK") || "slqs") + ".sock"
        connected: true
        parser: SplitParser { onRead: data => backend.onEvent(data) }
        onConnectionStateChanged: {
            if (!connected) { reconnect.restart(); return }
            // On (re)connect slkd re-sends the channel list; refresh the open
            // channel's messages (and thread) too — a slkd restart drops the
            // socket and would otherwise leave a stale/empty view.
            if (backend.currentChannelId !== "")
                safeWrite(JSON.stringify({ type: "recent", channel: backend.currentChannelId }) + "\n")
            if (backend.threadOpen && backend.threadParentTs !== "")
                safeWrite(JSON.stringify({ type: "replies", channel: backend.currentChannelId, thread: backend.threadParentTs }) + "\n")
        }
    }
    Component.onCompleted: lastRecv = Date.now()
    // Heartbeat-driven reconnect. slkd pings every 3s; if we've heard nothing for
    // 8s the socket is dead (sock.connected can't be trusted — it stays stuck-true
    // on a server-side close). Force a re-dial in two phases (drop, then connect a
    // tick later — doing both at once races the disconnect against the connect).
    Timer {
        id: reconnect
        interval: 1000; repeat: true; running: true
        property bool dropping: false
        onTriggered: {
            // Cold start / after a drop: the socket simply isn't connected yet (e.g. the
            // daemon hasn't bound it — it needs a network round-trip first). Re-dial every
            // tick until it takes; don't wait for the staleness window, which left the UI
            // empty on cold start because lastRecv was seeded to launch time (issue #2).
            if (!sock.connected) { dropping = false; sock.connected = true; return }
            // Connected but silent for 8s → Quickshell's `connected` is stuck-true after a
            // server-side close. Force a re-dial in two phases (drop, then connect next tick).
            const stale = (Date.now() - backend.lastRecv) > 8000
            if (!stale) { dropping = false; return }
            if (!dropping) { sock.connected = false; dropping = true }
            else { sock.connected = true; dropping = false }
        }
    }
}
