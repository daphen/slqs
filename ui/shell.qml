import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "."
import QsLib
import QsLib as Lib

FloatingWindow {
    id: win
    implicitWidth: 1180
    implicitHeight: 760

    // Keycap chip + muted label — canonical QsLib family components,
    // re-derived locally only to bake in the row anchoring.
    component StatusCap: Lib.KeyCap {
        anchors.verticalCenter: parent.verticalCenter
    }
    component CapLabel: Lib.CapLabel {
        anchors.verticalCenter: parent.verticalCenter
    }

    // Shared panel motion — one source of truth for every panel reveal/collapse
    // (sidebar, thread). Retune here and all of them change at once. Vaul drawer
    // curve: transform 0.2s cubic-bezier(0.165, 0.84, 0.44, 1) — a clean ease-out,
    // no overshoot. Use as the animation inside a Behavior: `Behavior on width { PanelMotion {} }`.
    component PanelMotion: NumberAnimation {
        duration: 200
        easing.type: Easing.BezierSpline
        easing.bezierCurve: [0.165, 0.84, 0.44, 1.0, 1.0, 1.0]
    }

    // Distinct per-backend title so niri-jump-or-exec can tell the Slack and
    // Discord instances apart (both share the org.quickshell app-id).
    title: (Quickshell.env("SLK_SOCK") === "dsqrd") ? "dsqrd" : "slqs"

    // Window-focus tracking for notification suppression lives in slkd, which
    // watches niri's event stream (FloatingWindow exposes no focus property).

    // ── vim modal state ──────────────────────────────────────────────────
    // The mirror of slk's internal/ui: a key router + panel focus. "Insert"
    // is derived from whether the composer holds focus, exactly like slk
    // flips to ModeInsert when the compose box is focused.
    property string focusedPanel: "sidebar"        // "sidebar" | "messages"
    readonly property bool insertMode: composer.inputHasFocus || thread.replyHasFocus || search1

    property bool search1: false   // /-search active (sidebar)

    readonly property bool isDiscord: Quickshell.env("SLK_SOCK") === "dsqrd"
    // Collapsible sidebar (Discord: `b` toggles it for more message room, and it
    // auto-hides when the window gets too narrow to fit sidebar + a usable pane).
    property bool sidebarCollapsed: false     // `b` preference: keep the sidebar hidden
    property bool sidebarPeeking: false        // transient: h/Tab peeked it open
    // 264 sidebar + ~296 for messages; below that the pane is unusable, so hide.
    // Bind to appRoot.width (the fill item that tracks the real surface size) —
    // FloatingWindow.width holds the requested/implicit size, not the live one.
    readonly property bool tooNarrow: isDiscord && appRoot.width < 560
    // Hidden when you asked for it (b) or there's no room (narrow) — unless you're
    // currently peeking it open. A single source of truth the sidebar width binds to.
    readonly property bool sidebarHidden: (sidebarCollapsed || tooNarrow) && !sidebarPeeking
    function toggleSidebar() {
        sidebarCollapsed = !sidebarCollapsed
        sidebarPeeking = false
        // don't leave the keyboard on a now-zero-width pane
        if (sidebarHidden && focusedPanel === "sidebar") focusPanel("messages")
        Backend.savePrefs({ sidebarCollapsed: sidebarCollapsed })   // #4: survive restarts
    }
    // #4: apply the persisted sidebar preference once the daemon replays prefs
    // (dsqrd only; slqs sends none, so it stays at the default).
    Connections {
        target: Backend
        function onPrefsLoaded() { win.sidebarCollapsed = Backend.prefs.sidebarCollapsed === true }
    }

    function focusPanel(name) {
        // Peek the sidebar open when you move INTO it (h / Tab); drop the peek once
        // you commit back to messages so it re-collapses if b/narrow want it hidden.
        sidebarPeeking = (name === "sidebar")
        focusedPanel = name
        sidebar.active = (name === "sidebar")
        // msgs.active / msgs.showNumbers are bound declaratively (below) so they
        // react to insert mode — no imperative set here.
    }
    function cyclePanel(d) { focusPanel(focusedPanel === "sidebar" ? "messages" : "sidebar") }
    // vim count prefix: digits accumulate, j/k consume it (e.g. 15k jumps 15).
    property int pendingCount: 0
    function consumeCount() { const n = pendingCount > 0 ? pendingCount : 1; pendingCount = 0; return n }
    function moveCursor(d) { const n = consumeCount(); focusedPanel === "sidebar" ? sidebar.move(d * n) : msgs.move(d * n) }
    function halfPage(d)   { focusedPanel === "sidebar" ? sidebar.move(d * 8) : msgs.half(d) }
    function scrollView(d) { if (focusedPanel === "messages") msgs.scroll(d) }   // ctrl+e/y: scroll, keep cursor
    function goTop()       { focusedPanel === "sidebar" ? sidebar.toTop()    : msgs.toTop() }
    function goBottom()    { focusedPanel === "sidebar" ? sidebar.toBottom() : msgs.toBottom() }
    function reactTo(msg)  { if (msg) { emojiPicker.target = msg; emojiPicker.show() } }
    function askDelete(msg) { if (msg && msg.ts) { confirmDelete.target = msg; confirmDelete.ask(Backend.plainText(msg.text)) } }
    function activate() {
        if (focusedPanel === "sidebar") { sidebar.openCurrent(); focusPanel("messages") }
        else if (focusedPanel === "messages") {
            const m = msgs.currentMessage()
            if (!m) return
            // A Discord reply → jump the cursor to the message it replied to.
            if (m.replyToTs) { msgs.jumpToTs(m.replyToTs); return }
            // Slack: Enter is ALWAYS the thread (the reply flow) — media stays
            // on `v`, links on `o`. The single-action Enter is Discord-only,
            // where messages have no thread to open.
            if (Backend.hasThreads) { Backend.openThread(m); return }
            if (Backend.enterAction(m)) return
        }
    }
    function backToNormal() { appRoot.forceActiveFocus() }

    // `m`: mute/unmute the channel under the sidebar cursor (Discord only). Already
    // muted → unmute directly (D5); else open the duration menu anchored to the row.
    function muteSelected() {
        if (!isDiscord) return
        const it = sidebar.cursorItem
        if (!it || !it.id) return
        if (Backend.channelMuted(it.id)) { Backend.muteChannel(it.id, false, null); return }
        muteMenu.muteTargetId = it.id
        muteMenu.show()
    }

    // When a staged attachment finishes uploading, drop into the composer so a
    // bare Enter sends it — the thread reply if a thread's open, else the channel.
    Connections {
        target: Backend
        function onAttachSettled() {
            if (Backend.threadOpen) thread.focusReply()
            else { win.focusPanel("messages"); composer.focusInput() }
        }
    }

    // Thread the pending upload belongs to, captured at trigger time (the async
    // picker returns later, and focus may have moved). "" = the channel.
    property string _uploadThread: ""

    // File attach ('u'): pop a floating yazi in chooser mode, then stage the
    // picked file for upload (goes out with the next message, like a paste).
    function openUpload() { _uploadThread = Backend.threadOpen ? Backend.threadParentTs : ""; filePicker.running = true }

    // 'U': upload the file at the path currently on the clipboard (e.g. the
    // recording path record-toggle copies on stop). No picker.
    function uploadClipboardPath() { _uploadThread = Backend.threadOpen ? Backend.threadParentTs : ""; clipPathReader.running = true }
    Process {
        id: clipPathReader
        command: ["sh", "-c", "wl-paste --no-newline 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                clipPathReader.running = false
                let p = (this.text || "").split("\n")[0].trim()
                if (p.startsWith("file://")) p = decodeURIComponent(p.slice(7))
                if (p.startsWith("~/")) p = Quickshell.env("HOME") + p.slice(1)
                if (p.startsWith("/")) Backend.uploadFile(p, win._uploadThread)
                else Backend.toast("Clipboard has no file path")
            }
        }
    }
    Process {
        id: filePicker
        command: ["sh", "-c",
            "f=$(mktemp); kitty --class slqs-upload -e yazi --chooser-file=\"$f\" \"$HOME\" >/dev/null 2>&1; cat \"$f\"; rm -f \"$f\""]
        stdout: StdioCollector {
            onStreamFinished: {
                filePicker.running = false
                const p = (this.text || "").split("\n")[0].trim()
                if (p.length > 0) Backend.uploadFile(p, win._uploadThread)
            }
        }
    }

    // ── key handling as a small state machine ────────────────────────────
    // Each mode is a {keyId → action} table. routeKey normalizes the event to
    // a keyId, picks the table for the current mode, and dispatches. Adding a
    // binding = one line in the relevant table; no nested if/else.
    function closeThreadAction() { Backend.closeThread(); backToNormal() }
    function closeProfileAction() { Backend.closeProfile(); backToNormal() }

    function currentMode() {
        if (Backend.profileOpen) return "profile"
        if (Backend.threadOpen) return "thread"
        if (Backend.threadsView && focusedPanel === "messages") return "threadsPage"
        if (Backend.mentionsView && focusedPanel === "messages") return "mentionsPage"
        return "channel"
    }

    // Normalize a key event to a stable id used as the keymap lookup key.
    function keyId(e, ctrl) {
        switch (e.key) {
            case Qt.Key_Escape:  return "esc"
            case Qt.Key_Return:
            case Qt.Key_Enter:   return "enter"
            case Qt.Key_Tab:     return "tab"
            case Qt.Key_Backtab: return "shift+tab"
        }
        if (ctrl) {
            if ((e.modifiers & Qt.ShiftModifier) && e.key === Qt.Key_R) return "ctrl+shift+r"
            switch (e.key) {
                case Qt.Key_D: return "ctrl+d"
                case Qt.Key_U: return "ctrl+u"
                case Qt.Key_G: return "ctrl+g"
                case Qt.Key_K: return "ctrl+k"
                case Qt.Key_H: return "ctrl+h"
                case Qt.Key_L: return "ctrl+l"
                case Qt.Key_E: return "ctrl+e"
                case Qt.Key_Y: return "ctrl+y"
                case Qt.Key_S: return "ctrl+s"
                case Qt.Key_O: return "ctrl+o"
                case Qt.Key_I: return "ctrl+i"
            }
            return ""   // unmapped ctrl combo → ignore
        }
        return e.text   // j k h l g i q /
    }

    // ctrl+s: with exactly two workspaces a picker is ceremony — flip straight
    // to the other one; three or more still get the picker.
    function switchWorkspaceOrPick() {
        if (Backend.workspaces.length === 2) Backend.cycleWorkspace(1)
        else workspacePicker.show()
    }
    function switchWorkspaceHelp(kind) {
        return (Backend.workspaces.length === 2 ? "Toggle " : "Switch ") + kind
    }

    // Each entry is { act, help, cat }: `act` runs on the key (routeKey calls it),
    // `help`/`cat` feed the `?` cheat sheet (KeybindHelp reads this table live, so
    // it can never drift). `help` may be a function for app-specific wording.
    // cat ∈ nav | chats | msg | thread | view. Entries are ordered by category for
    // clean display; routeKey looks up by key id, so order is cosmetic.
    readonly property var keymaps: ({
        "channel": {
            // navigate
            "j":        { act: () => moveCursor(1),  help: "Move down", cat: "nav" },
            "k":        { act: () => moveCursor(-1), help: "Move up", cat: "nav" },
            "h":        { act: () => focusPanel("sidebar"),  help: "Focus sidebar", cat: "nav" },
            "l":        { act: () => focusPanel("messages"), help: "Focus messages", cat: "nav" },
            "g":        { act: () => goTop(),    help: "Jump to top", cat: "nav" },
            "G":        { act: () => goBottom(), help: "Jump to bottom", cat: "nav" },
            "ctrl+d":   { act: () => halfPage(1),  help: "Half-page down", cat: "nav" },
            "ctrl+u":   { act: () => halfPage(-1), help: "Half-page up", cat: "nav" },
            "ctrl+e":   { act: () => scrollView(1),  help: "Scroll down, keep cursor", cat: "nav" },
            "ctrl+y":   { act: () => scrollView(-1), help: "Scroll up, keep cursor", cat: "nav" },
            "ctrl+g":   { act: () => goBottom(),    help: "Jump to bottom", cat: "nav" },
            "tab":      { act: () => cyclePanel(1),  help: "Next panel", cat: "nav" },
            "shift+tab":{ act: () => cyclePanel(-1), help: "Previous panel", cat: "nav" },
            // chats
            "enter":    { act: () => activate(), help: "Open selected", cat: "chats" },
            "/":        { act: () => palette.show(), help: "Jump palette", cat: "chats" },
            "m":        { act: () => win.muteSelected(), help: "Mute channel", cat: "chats" },
            "b":        { act: () => { if (win.isDiscord) win.toggleSidebar(); else browse.show() },
                          help: () => win.isDiscord ? "Toggle sidebar" : "Browse channels", cat: "chats" },
            "s":        { act: () => sidebar.toggleStarCurrent(), help: "Star / unstar channel", cat: "chats" },
            "u":        { act: () => win.openUpload(), help: "Attach a file", cat: "chats" },
            // slqs only (Discord has no equivalent): d = DM anyone, I = invite to channel.
            "d":        { act: () => { if (!Backend.railHidden) peoplePicker.showDM() }, help: () => Backend.railHidden ? "" : "Message someone", cat: "chats" },
            "I":        { act: () => { if (!Backend.railHidden) peoplePicker.showInvite() }, help: () => Backend.railHidden ? "" : "Invite to channel", cat: "chats" },
            "ctrl+k":   { act: () => palette.show(), help: "Jump palette", cat: "chats" },
            "ctrl+o":   { act: () => Backend.toggleLastChannel(), help: "Last channel", cat: "chats" },
            "ctrl+i":   { act: () => Backend.gotoFirstUnread(), help: "Go to first unread", cat: "chats" },
            "ctrl+s":   { act: () => switchWorkspaceOrPick(), help: () => switchWorkspaceHelp(Backend.railHidden ? "server" : "workspace"), cat: "chats" },
            // Directional panel focus, insert-mode friendly (the composer maps the
            // same chords through panelMove). Workspace switching stays on ctrl+s.
            "ctrl+l":   { act: () => focusPanel("messages"), help: "Focus messages", cat: "nav" },
            "ctrl+h":   { act: () => focusPanel("sidebar"),  help: "Focus sidebar", cat: "nav" },
            // messages
            "i":        { act: () => { focusPanel("messages"); composer.focusInput() }, help: "Compose", cat: "msg" },
            "R":        { act: () => { if (focusedPanel === "messages") { composer.startReply(msgs.currentMessage()); focusPanel("messages") } }, help: () => Backend.hasThreads ? "Reply in thread" : "Reply to message", cat: "msg" },
            "e":        { act: () => { if (focusedPanel === "messages") { const m = msgs.currentMessage(); if (m && m.mine) composer.startEdit(m) } }, help: "Edit your message", cat: "msg" },
            "D":        { act: () => { if (focusedPanel === "messages") askDelete(msgs.currentMessage()) }, help: "Delete your message", cat: "msg" },
            "S":        { act: () => { if (focusedPanel === "messages") Backend.downloadMedia(msgs.currentMessage()) }, help: "Save media", cat: "msg" },
            "r":        { act: () => { if (focusedPanel === "messages") reactTo(msgs.currentMessage()) }, help: "React", cat: "msg" },
            "y":        { act: () => { if (focusedPanel === "messages") Backend.copyText(msgs.currentMessage()) }, help: "Copy text", cat: "msg" },
            "o":        { act: () => { if (focusedPanel === "messages") Backend.openChannelRef(msgs.currentMessage()) }, help: "Open link", cat: "msg" },
            "v":        { act: () => { if (focusedPanel === "messages") Backend.viewImage(msgs.currentMessage()) }, help: "View image", cat: "msg" },
            // voice notes are Discord-only (Slack's clips API is closed)
            "V":        { act: () => { if (win.isDiscord) Backend.voiceRecord() },
                          help: () => win.isDiscord ? "Record voice note" : "", cat: "msg" },
            // author actions are slqs-only (Discord lacks the daemon verbs)
            "Y":        { act: () => { if (focusedPanel === "messages") Backend.copyLink(msgs.currentMessage()) }, help: "Copy message link", cat: "msg" },
            "M":        { act: () => { if (!Backend.railHidden && focusedPanel === "messages") { const m = msgs.currentMessage(); if (m && m.uid) Backend.openDM(m.uid) } },
                          help: () => Backend.railHidden ? "" : "DM author", cat: "msg" },
            "P":        { act: () => { if (focusedPanel === "messages") { const m = msgs.currentMessage(); if (m && m.uid) Backend.openProfile(m.uid) } },
                          help: () => "View profile", cat: "msg" },
            // views & general
            "?":        { act: () => help.show(), help: "This help", cat: "view" },
            "ctrl+shift+r": { act: () => Backend.checkForUpdates(), help: "Check for updates", cat: "view" },
            "U":        { act: () => {
                              if (Backend.updateAvailable && Backend.updateChangelog.length > 0) changelog.show()
                              else if (Backend.updateAvailable) Backend.applyUpdate()
                              else win.uploadClipboardPath()
                          }, help: "Upload file path from clipboard", cat: "chats" },
            "esc":      { act: () => backToNormal(), help: "Back to normal", cat: "view" },
        },
        "thread": {
            "j":      { act: () => thread.move(1),  help: "Move down", cat: "nav" },
            "k":      { act: () => thread.move(-1), help: "Move up", cat: "nav" },
            "g":      { act: () => thread.move(-9999), help: "Jump to top", cat: "nav" },
            "G":      { act: () => thread.move(9999),  help: "Jump to bottom", cat: "nav" },
            "ctrl+d": { act: () => thread.move(8),  help: "Half-page down", cat: "nav" },
            "ctrl+u": { act: () => thread.move(-8), help: "Half-page up", cat: "nav" },
            "ctrl+e": { act: () => thread.scroll(1),  help: "Scroll down, keep cursor", cat: "nav" },
            "ctrl+y": { act: () => thread.scroll(-1), help: "Scroll up, keep cursor", cat: "nav" },
            "ctrl+g": { act: () => thread.move(9999), help: "Jump to bottom", cat: "nav" },
            "enter":  { act: () => Backend.enterAction(thread.currentMessage()), help: "Open media/link", cat: "msg" },
            "v":      { act: () => Backend.viewImage(thread.currentMessage()), help: "View image", cat: "msg" },
            "M":      { act: () => { if (!Backend.railHidden) { const m = thread.currentMessage(); if (m && m.uid) Backend.openDM(m.uid) } },
                        help: () => Backend.railHidden ? "" : "DM author", cat: "msg" },
            "P":      { act: () => { const m = thread.currentMessage(); if (m && m.uid) Backend.openProfile(m.uid) },
                        help: () => "View profile", cat: "msg" },
            "o":      { act: () => Backend.openChannelRef(thread.currentMessage()), help: "Open link", cat: "msg" },
            "r":      { act: () => reactTo(thread.currentMessage()), help: "React", cat: "msg" },
            "y":      { act: () => Backend.copyText(thread.currentMessage()), help: "Copy text", cat: "msg" },
            "Y":      { act: () => Backend.copyLink(thread.currentMessage()), help: "Copy message link", cat: "msg" },
            "e":      { act: () => { const m = thread.currentMessage(); if (m && m.mine) thread.startEdit(m) }, help: "Edit your message", cat: "msg" },
            "D":      { act: () => askDelete(thread.currentMessage()), help: "Delete your message", cat: "msg" },
            "S":      { act: () => Backend.downloadMedia(thread.currentMessage()), help: "Save media", cat: "msg" },
            "ctrl+k": { act: () => palette.show(), help: "Jump palette", cat: "chats" },
            "ctrl+o": { act: () => Backend.toggleLastChannel(), help: "Last channel", cat: "chats" },
            "ctrl+i": { act: () => Backend.gotoFirstUnread(), help: "Go to first unread", cat: "chats" },
            "ctrl+s": { act: () => switchWorkspaceOrPick(), help: () => switchWorkspaceHelp("workspace"), cat: "chats" },
            "u":      { act: () => win.openUpload(), help: "Attach a file", cat: "chats" },
            "U":      { act: () => win.uploadClipboardPath(), help: "Upload file path from clipboard", cat: "chats" },
            "ctrl+h": { act: () => closeThreadAction(), help: "Back to channel", cat: "nav" },
            // thread-specific (feeds the THREADS section of the cheat sheet)
            "i":      { act: () => thread.focusReply(), help: "Reply in thread", cat: "thread" },
            "q":      { act: () => closeThreadAction(), help: "Close thread", cat: "thread" },
            "h":      { act: () => closeThreadAction(), help: "Back to channel", cat: "thread" },
            "?":      { act: () => help.show(), help: "This help", cat: "view" },
            "ctrl+shift+r": { act: () => Backend.checkForUpdates(), help: "Check for updates", cat: "view" },
            "esc":    { act: () => closeThreadAction(), help: "Close thread", cat: "view" },
        },
        "profile": {
            "M":      { act: () => { const u = Backend.profileUser; closeProfileAction(); Backend.openDM(u) }, help: "DM them", cat: "profile" },
            "q":      { act: () => closeProfileAction(), help: "Close profile", cat: "profile" },
            "h":      { act: () => closeProfileAction(), help: "Back to channel", cat: "profile" },
            "ctrl+h": { act: () => closeProfileAction(), help: "Back to channel", cat: "nav" },
            "?":      { act: () => help.show(), help: "This help", cat: "view" },
            "esc":    { act: () => closeProfileAction(), help: "Close profile", cat: "view" },
        },
        "threadsPage": {
            "j":      { act: () => threadsPage.move(1),  help: "Move down", cat: "nav" },
            "k":      { act: () => threadsPage.move(-1), help: "Move up", cat: "nav" },
            "g":      { act: () => threadsPage.toTop(),    help: "Jump to top", cat: "nav" },
            "G":      { act: () => threadsPage.toBottom(), help: "Jump to bottom", cat: "nav" },
            "ctrl+d": { act: () => threadsPage.half(1),  help: "Half-page down", cat: "nav" },
            "ctrl+u": { act: () => threadsPage.half(-1), help: "Half-page up", cat: "nav" },
            "ctrl+g": { act: () => threadsPage.toBottom(), help: "Jump to bottom", cat: "nav" },
            "h":      { act: () => focusPanel("sidebar"), help: "Focus sidebar", cat: "nav" },
            "ctrl+k": { act: () => palette.show(), help: "Jump palette", cat: "chats" },
            "ctrl+i": { act: () => Backend.gotoFirstUnread(), help: "Go to first unread", cat: "chats" },
            "ctrl+s": { act: () => switchWorkspaceOrPick(), help: () => switchWorkspaceHelp("workspace"), cat: "chats" },
            // threads-view specific (feeds the THREADS section)
            "enter":  { act: () => threadsPage.openCurrent(), help: "Open thread", cat: "thread" },
            "D":      { act: () => { const t = Backend.currentSubThreads[threadsPage.currentIndex]
                              if (t) { confirmUnsub.target = t; confirmUnsub.ask("#" + (t.channelName || "") + " · " + (t.title || "")) } }, help: "Unsubscribe from thread", cat: "thread" },
            "q":      { act: () => Backend.hideThreadsView(), help: "Close threads view", cat: "thread" },
            "?":      { act: () => help.show(), help: "This help", cat: "view" },
            "ctrl+shift+r": { act: () => Backend.checkForUpdates(), help: "Check for updates", cat: "view" },
            "esc":    { act: () => Backend.hideThreadsView(), help: "Close threads view", cat: "view" },
        },
        "mentionsPage": {
            "j":      { act: () => mentionsPage.move(1),  help: "Move down", cat: "nav" },
            "k":      { act: () => mentionsPage.move(-1), help: "Move up", cat: "nav" },
            "g":      { act: () => mentionsPage.toTop(),    help: "Jump to top", cat: "nav" },
            "G":      { act: () => mentionsPage.toBottom(), help: "Jump to bottom", cat: "nav" },
            "ctrl+d": { act: () => mentionsPage.half(1),  help: "Half-page down", cat: "nav" },
            "ctrl+u": { act: () => mentionsPage.half(-1), help: "Half-page up", cat: "nav" },
            "h":      { act: () => focusPanel("sidebar"), help: "Focus sidebar", cat: "nav" },
            "ctrl+k": { act: () => palette.show(), help: "Jump palette", cat: "chats" },
            "enter":  { act: () => mentionsPage.openCurrent(), help: "Open mention", cat: "mention" },
            "q":      { act: () => Backend.hideMentionsView(), help: "Close mentions view", cat: "mention" },
            "?":      { act: () => help.show(), help: "This help", cat: "view" },
            "ctrl+shift+r": { act: () => Backend.checkForUpdates(), help: "Check for updates", cat: "view" },
            "esc":    { act: () => Backend.hideMentionsView(), help: "Close mentions view", cat: "view" },
        },
    })

    function routeKey(e) {
        const ctrl = e.modifiers & Qt.ControlModifier
        // Changelog modal (#5): ↵ applies the update, j/k scroll, esc/q close.
        if (changelog.open) {
            if (e.key === Qt.Key_Escape || e.key === Qt.Key_Q) changelog.close()
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { changelog.close(); Backend.applyUpdate() }
            else if (ctrl && (e.key === Qt.Key_D || e.key === Qt.Key_U)) changelog.scrollPage(e.key === Qt.Key_D ? 1 : -1)
            else if (e.key === Qt.Key_J) changelog.scrollStep(48)
            else if (e.key === Qt.Key_K) changelog.scrollStep(-48)
            e.accepted = true; return
        }
        // Cheat sheet: driven from here (the shell keeps focus; handing it to the
        // overlay proved unreliable). esc closes / clears; / filters; typing edits.
        if (help.open) {
            if (e.key === Qt.Key_Escape) {
                if (help.searching || help.query) help.resetSearch(); else help.close()
            } else if (e.key === Qt.Key_Slash && !help.searching) {
                help.searching = true
            } else if (!help.searching && (e.key === Qt.Key_Q || e.text === "?")) {
                help.close()
            } else if (ctrl && (e.key === Qt.Key_D || e.key === Qt.Key_U)) {
                help.scrollPage(e.key === Qt.Key_D ? 1 : -1)
            } else if (help.searching) {
                if (e.key === Qt.Key_Backspace) help.query = help.query.slice(0, -1)
                else if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 0x20) help.query += e.text
            } else if (e.key === Qt.Key_J) help.scrollBy(48)
            else if (e.key === Qt.Key_K) help.scrollBy(-48)
            e.accepted = true; return
        }
        const id = keyId(e, ctrl)
        if (!id) return
        // a live voice recording claims enter (send) and esc (cancel) before anything else
        if (Backend.voiceState === "recording" && (id === "enter" || id === "esc")) {
            if (id === "enter") Backend.voiceSend(); else Backend.voiceCancel()
            e.accepted = true; return
        }
        // q stops in-line audio playback wherever you are
        if (Backend.playingId && id === "q") {
            Backend.playStop(); e.accepted = true; return
        }
        // Ctrl+D/U must not multi-fire on a held/repeated press (one tap = one half-page)
        if (e.isAutoRepeat && (id === "ctrl+d" || id === "ctrl+u")) { e.accepted = true; return }
        // numeric count prefix (for j/k jumps like 15k); 0 only extends a count
        if (!ctrl && id.length === 1 && id >= "0" && id <= "9") {
            if (id !== "0" || pendingCount > 0) {
                pendingCount = pendingCount * 10 + parseInt(id)
                e.accepted = true
                return
            }
        }
        const entry = keymaps[currentMode()][id]
        if (entry) { entry.act(); e.accepted = true }
        if (id !== "j" && id !== "k") pendingCount = 0   // drop a dangling count
    }

    Item {
        id: appRoot
        anchors.fill: parent
        focus: true
        Keys.onPressed: e => win.routeKey(e)
        Component.onCompleted: forceActiveFocus()

        Rectangle {
            anchors.fill: parent
            // reference layout: flat canvas, panes float as cards on it
            color: Theme.bg_alt

            Row {
                id: mainRow
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.bottom: statusbar.top

                RailBar {
                    id: rail
                    visible: Backend.useRail && !Backend.railHidden
                    width: (Backend.useRail && !Backend.railHidden) ? 56 : 0
                    height: parent.height
                }

                Sidebar {
                    id: sidebar
                    clip: true
                    height: parent.height
                    width: win.sidebarHidden ? 0 : 264
                    Behavior on width { PanelMotion {} }
                    onThreadsClicked: { Backend.showThreadsView(); win.focusPanel("messages") }
                    onMentionsClicked: { Backend.showMentionsView(); win.focusPanel("messages") }
                    onWorkspacePickerRequested: workspacePicker.show()
                }

                Item {
                    width: parent.width - sidebar.width - rail.width; height: parent.height

                    // focused-panel accent: full border (message pane, no thread open)
                    Rectangle {
                        id: header
                        width: parent.width; height: 52; color: "transparent"
                        Row {
                            anchors.left: parent.left; anchors.leftMargin: 18
                            anchors.verticalCenter: parent.verticalCenter; spacing: 9
                            Text { text: "#"; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 19 }
                            Text { text: Backend.currentChannel; color: Theme.fg; anchors.verticalCenter: parent.verticalCenter
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17; font.weight: 500 }
                            Rectangle { visible: Backend.currentTopic.length > 0; width: 1; height: 16; color: Theme.hairline
                                        anchors.verticalCenter: parent.verticalCenter }
                            Text { anchors.verticalCenter: parent.verticalCenter
                                   // collapse the (often multi-line) topic to one elided line
                                   text: Backend.currentTopic.replace(/[\r\n]+/g, "  ")
                                   color: Theme.fg_muted; elide: Text.ElideRight
                                   maximumLineCount: 1; wrapMode: Text.NoWrap
                                   width: Math.max(0, header.width - 240)
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14 }
                        }
                        // Previewing a channel we haven't joined (opened via a permalink):
                        // offer to join so it sticks in the sidebar and you can reply.
                        Rectangle {
                            visible: Backend.viewingNonMember
                            anchors.right: parent.right; anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            width: joinLbl.implicitWidth + 22; height: 26; radius: 6
                            color: joinMA.containsMouse ? Theme.selection : Theme.surface
                            border.width: 1; border.color: Theme.sky
                            Text { id: joinLbl; anchors.centerIn: parent
                                   text: "+ Join channel"; color: Theme.sky
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13; font.weight: 500 }
                            MouseArea { id: joinMA; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: Backend.joinCurrent() }
                        }
                    }

                    Lib.Card {
                        id: chatCard
                        // Left margin is a tight 4px gap to the sidebar when it's
                        // open, but grows to match the 12px right margin as the
                        // sidebar closes — so a closed sidebar leaves the card
                        // evenly padded. Tracks sidebar.width so it springs in sync.
                        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
                                  topMargin: 6
                                  leftMargin: 4 + 8 * (1 - Math.min(1, sidebar.width / 264))
                                  rightMargin: 12; bottomMargin: 12 }
                        // focused-panel accent: the mlqs inbox hairline
                        border.width: 1
                        border.color: (win.focusedPanel === "messages" && !Backend.threadOpen)
                                    ? Theme.hairlineSoft : "transparent"
                    }

                    MessageList {
                        id: msgs
                        anchors.top: chatCard.top; anchors.topMargin: 6
                        anchors.left: chatCard.left; anchors.right: chatCard.right
                        anchors.bottom: footer.top
                        anchors.bottomMargin: 10
                        // Highlight stays in insert mode only when targeting a specific
                        // message (reply/edit); numbers show in normal mode only.
                        active: win.focusedPanel === "messages" && !Backend.threadOpen
                                && (!win.insertMode || composer.replyTs !== "" || composer.editingTs !== "")
                        showNumbers: win.focusedPanel === "messages" && !Backend.threadOpen && !win.insertMode
                    }

                    Item {
                        id: footer
                        anchors.left: chatCard.left; anchors.right: chatCard.right
                        anchors.bottom: chatCard.bottom
                        height: composer.height + typingRow.height + 16

                        Item {
                            id: typingRow
                            width: parent.width; anchors.top: parent.top
                            height: Backend.typing ? 22 : 0
                            clip: true
                            Behavior on height { NumberAnimation { duration: 120 } }
                            Text { 
                                x: 20; anchors.top: parent.top; anchors.bottom: parent.bottom
                                verticalAlignment: Text.AlignVCenter
                                text: Backend.typingWho + " is typing…"
                                color: Theme.fg_muted
                                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13
                            }
                        }

                        Composer {
                            id: composer
                            anchors.top: typingRow.bottom; anchors.topMargin: 2
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.leftMargin: Theme.insetCard; anchors.rightMargin: Theme.insetCard
                            onExitInsert: win.backToNormal()
                            onOpenPalette: palette.show()
                            onGifCommand: (q) => gifPicker.show(q)
                            onPageScroll: (d) => win.halfPage(d)
                            onPanelMove: (d) => win.focusPanel(d < 0 ? "sidebar" : "messages")
                            // Clicking into the composer makes the messages panel the
                            // focused one, so the state machine is in sync on Esc.
                            onInputHasFocusChanged: if (inputHasFocus) win.focusPanel("messages")
                        }
                    }

                    // "Opening media…" badge — v starts an async full-res fetch, so
                    // show persistent feedback until the viewer appears. Centered in
                    // the chat panel, floating just above the input.
                    Rectangle {
                        id: mediaLoad
                        z: 201
                        visible: opacity > 0
                        opacity: Backend.mediaLoading ? 1 : 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: footer.top; anchors.bottomMargin: 8
                        width: mlRow.implicitWidth + 28; height: 32; radius: 8
                        color: Theme.mode === "light" ? Theme.ink : Theme.fg
                        border.width: 1; border.color: Theme.hairline
                        Behavior on opacity { NumberAnimation { duration: 140 } }
                        Row {
                            id: mlRow; anchors.centerIn: parent; spacing: 8
                            Rectangle {
                                width: 8; height: 8; radius: 4; color: Theme.cursor
                                anchors.verticalCenter: parent.verticalCenter
                                SequentialAnimation on opacity {
                                    running: Backend.mediaLoading; loops: Animation.Infinite
                                    NumberAnimation { from: 1; to: 0.25; duration: 550 }
                                    NumberAnimation { from: 0.25; to: 1; duration: 550 }
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Opening media…"; color: Theme.bg
                                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13
                            }
                        }
                    }

                    // Voice-note badge — same grammar as the media badge: shows the
                    // running recording (elapsed + the two live binds) or the send.
                    Rectangle {
                        id: voiceBadge
                        z: 201
                        visible: opacity > 0
                        opacity: Backend.voiceState !== "idle" ? 1 : 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: footer.top; anchors.bottomMargin: 8
                        width: vbRow.implicitWidth + 28; height: 32; radius: 8
                        color: Theme.mode === "light" ? Theme.ink : Theme.fg
                        border.width: 1; border.color: Theme.hairline
                        Behavior on opacity { NumberAnimation { duration: 140 } }
                        property int secs: 0
                        Timer {
                            interval: 1000; repeat: true; triggeredOnStart: true
                            running: Backend.voiceState === "recording"
                            onTriggered: voiceBadge.secs = Math.max(0, Math.round((Date.now() - Backend.voiceStartedAt) / 1000))
                        }
                        Row {
                            id: vbRow; anchors.centerIn: parent; spacing: 8
                            Rectangle {
                                width: 8; height: 8; radius: 4; color: Theme.red
                                anchors.verticalCenter: parent.verticalCenter
                                SequentialAnimation on opacity {
                                    running: Backend.voiceState === "recording"; loops: Animation.Infinite
                                    NumberAnimation { from: 1; to: 0.25; duration: 550 }
                                    NumberAnimation { from: 0.25; to: 1; duration: 550 }
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Backend.voiceState === "sending" ? "Sending voice note…"
                                    : "Recording  " + Math.floor(voiceBadge.secs / 60) + ":" + ("0" + (voiceBadge.secs % 60)).slice(-2) + "   ⏎ send · esc cancel"
                                color: Theme.bg
                                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13
                            }
                        }
                    }

                    ThreadsPage {
                        id: threadsPage
                        anchors.fill: parent
                        // threads are a Slack-only concept — never render on a
                        // backend without them (Discord)
                        visible: Backend.hasThreads && Backend.threadsView
                        active: Backend.hasThreads && Backend.threadsView && !Backend.threadOpen
                        z: 4
                    }

                    MentionsPage {
                        id: mentionsPage
                        anchors.fill: parent
                        visible: Backend.hasThreads && Backend.mentionsView
                        active: Backend.hasThreads && Backend.mentionsView && !Backend.threadOpen
                        z: 4
                    }

                    // The whole panel slides in from the right at a FIXED width,
                    // so its wrapping message text lays out once and never
                    // reflows/squishes — the shared panel spring drives x.
                    ThreadPanel {
                        id: thread
                        width: Math.min(560, parent.width * 0.58)
                        anchors.top: parent.top; anchors.bottom: parent.bottom
                        anchors.topMargin: 8; anchors.bottomMargin: 12
                        anchors.right: parent.right
                        // slide via a panel-width-relative right margin (not an x
                        // tied to parent.width) so toggling the sidebar — which
                        // animates the container width — can't drag a closed panel in.
                        anchors.rightMargin: Backend.threadOpen ? 12 : -(width + 24)
                        Behavior on anchors.rightMargin { PanelMotion {} }
                        // never render a thread container on a threadless backend (Discord)
                        visible: Backend.hasThreads && anchors.rightMargin > -width
                        z: 5
                        onExitReply: win.backToNormal()
                        onOpenPalette: palette.show()
                        // H = back to the channel (closes the thread panel); L = rightmost, just normal mode.
                        onPanelMove: (d) => { if (d < 0) win.closeThreadAction(); else win.backToNormal() }
                    }

                    // Profile card panel: same slide-in grammar as the thread
                    // panel, narrower. Only one right panel at a time — Backend
                    // closes whichever other panel is open. Works for slqs and
                    // dsqrd; each daemon serves the `profile` event.
                    ProfilePanel {
                        id: profilePanel
                        width: Math.min(420, parent.width * 0.44)
                        anchors.top: parent.top; anchors.bottom: parent.bottom
                        anchors.topMargin: 8; anchors.bottomMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: Backend.profileOpen ? 12 : -(width + 24)
                        Behavior on anchors.rightMargin { PanelMotion {} }
                        visible: anchors.rightMargin > -width
                        z: 6
                    }
                }
            }

            // ── statusbar (picker-footer style) ────────────────────────────
            Rectangle {
                id: statusbar
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                height: 36; color: Theme.surface0
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.hairline }
                Row {
                    id: leftStatus
                    anchors.left: parent.left; anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Rectangle {
                        width: modeLabel.implicitWidth + 16; height: 22; radius: 7
                        anchors.verticalCenter: parent.verticalCenter
                        color: win.insertMode ? Theme.cursor : Theme.green
                        Text { 
                            id: modeLabel; anchors.centerIn: parent
                            text: win.insertMode ? "INSERT" : "NORMAL"
                            // Contrast against the chip's own bg: dark text on a light
                            // chip (dark-mode green / orange), light text on a dark chip
                            // (light-mode green) — fixes dark-on-dark-green in light mode.
                            color: (parent.color.r * 0.299 + parent.color.g * 0.587 + parent.color.b * 0.114) > 0.5 ? Theme.ink : Theme.brightWhite
                            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                            font.pixelSize: 11; font.weight: 500; font.letterSpacing: 0.5
                        }
                    }
                    Text { 
                        anchors.verticalCenter: parent.verticalCenter
                        text: "panel: " + win.focusedPanel + "   #" + Backend.currentChannel
                              + (win.pendingCount > 0 ? "      " + win.pendingCount : "")
                        color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12
                    }
                }
                // Persistent help affordance — stays pinned in the corner even
                // when the rest of the hints collapse on a narrow window.
                Row {
                    id: helpBadge
                    visible: !Backend.updateAvailable
                    anchors.right: parent.right; anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    StatusCap { text: "?" }
                    CapLabel { text: "cheatsheet" }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: help.show() }
                }
                Row {
                    id: hintRow
                    visible: !Backend.updateAvailable
                    // hide when the left status text would collide — opacity
                    // (not visible) keeps implicitWidth measurable, so the
                    // check can't feed back on itself. The ? badge stays put.
                    opacity: (statusbar.width - leftStatus.width - implicitWidth - helpBadge.width - 70) >= 0 ? 1 : 0
                    anchors.right: helpBadge.left; anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    StatusCap { text: "ctrl k" }
                    CapLabel { text: "jump" }
                }
                Text { 
                    visible: Backend.updateAvailable
                    anchors.right: parent.right; anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: "⟳ update available · " + Backend.updateCurrent + " → " + Backend.updateLatest + " · U to apply"
                    color: Theme.orange
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12
                }
            }

            ChannelPalette {
                id: palette
                z: 100
                onOpenChanged: if (!open) win.backToNormal()
                onChannelSelected: win.focusPanel("messages")
            }

            WorkspacePicker {
                id: workspacePicker
                z: 101
                onOpenChanged: if (!open) win.backToNormal()
            }

            EmojiPicker {
                id: emojiPicker
                z: 101
                property var target: null   // message being reacted to
                onPicked: name => { if (target) Backend.toggleReaction(target, name); target = null }
                onOpenChanged: if (!open) win.backToNormal()
            }

            GifPicker {
                id: gifPicker
                z: 101
                onOpenChanged: if (!open) win.backToNormal()
            }

            BrowsePicker {
                id: browse
                z: 101
                onOpenChanged: if (!open) win.backToNormal()
            }

            PeoplePicker {
                id: peoplePicker
                z: 101
                onOpenChanged: if (!open) win.backToNormal()
            }

            ConfirmDialog {
                id: confirmDelete
                z: 102
                property var target: null
                onConfirmed: { if (target) Backend.deleteMessage(target); target = null }
                onOpenChanged: if (!open) win.backToNormal()
            }

            ConfirmDialog {
                id: confirmUnsub
                z: 102
                title: "Unsubscribe from this thread?"
                property var target: null
                onConfirmed: { if (target) Backend.unsubThread(target.channel, target.ts); target = null }
                onOpenChanged: if (!open) win.backToNormal()
            }

            // Oversized image/video: the daemon asks before doing anything, so
            // yes → compress-and-stage, no → nothing uploaded.
            ConfirmDialog {
                id: confirmCompress
                z: 102
                title: "Compress and send?"
                property var target: null
                onConfirmed: { if (target) Backend.compressUpload(target.channel, target.thread, target.path); target = null }
                onOpenChanged: if (!open) { target = null; win.backToNormal() }
                Connections {
                    target: Backend
                    function onAskCompress(info) {
                        confirmCompress.target = info
                        confirmCompress.ask(info.name + "  ·  " + info.mb + " MB → over your " + (info.limit || 10) + " MB Discord limit")
                    }
                }
            }

            KeybindHelp {
                id: help
                z: 103
                keymaps: win.keymaps
                onOpenChanged: if (!open) win.backToNormal()
            }

            // "What's new" before applying an update (#5). Shell-routed; opened
            // from the U keybind when the daemon supplied a changelog.
            ChangelogModal {
                id: changelog
                z: 104
                entries: Backend.updateChangelog
                fromRev: Backend.updateCurrent
                toRev: Backend.updateLatest
                onOpenChanged: if (!open) win.backToNormal()
            }

            // Mute-duration menu (Discord). `m` opens it anchored to the sidebar
            // cursor row; picking a duration sends muteChannel. No initials chips.
            Dropdown {
                id: muteMenu
                z: 105
                property string muteTargetId: ""
                anchorItem: sidebar.cursorItem
                grabsKeys: true
                showChips: false
                scrimOpacity: 0.28
                panelWidth: 190
                model: [
                    { id: 900,   label: "15 minutes" },
                    { id: 1800,  label: "30 minutes" },
                    { id: 3600,  label: "1 hour" },
                    { id: 28800, label: "8 hours" }
                ]
                onActivated: secs => Backend.muteChannel(muteMenu.muteTargetId, true, secs)
                onClosed: win.backToNormal()
            }

            // Transient status toast (e.g. "Copied message", "muted #chan"), fired
            // by Backend.toast(). The family FeedbackPill (design system) — same
            // component mlqs uses, so notifications match across the apps.
            FeedbackPill {
                id: toast
                z: 200
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom; anchors.bottomMargin: 30
                Connections {
                    target: Backend
                    function onToast(message) { toast.show(message) }
                }
            }

        }
    }

    Component.onCompleted: { focusPanel("sidebar"); console.log("PROTO_READY") }
}
