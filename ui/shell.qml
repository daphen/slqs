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

    // Shared panel spring — one source of truth for every panel reveal/collapse
    // (sidebar, thread). Retune here and all of them change at once. Use as the
    // animation inside a Behavior: `Behavior on width { PanelMotion {} }`.
    component PanelMotion: NumberAnimation {
        duration: 340
        easing.type: Easing.BezierSpline
        easing.bezierCurve: [0.34, 1.15, 0.64, 1.0, 1.0, 1.0]
    }

    // Distinct per-backend title so niri-jump-or-exec can tell the Slack and
    // Discord instances apart (both share the org.quickshell app-id).
    title: (Quickshell.env("SLK_SOCK") === "dsqrd") ? "discord-client" : "slk-client"

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
    // Collapsible sidebar (Discord: `b` toggles it for more message room).
    property bool sidebarCollapsed: false   // `b` preference: keep the sidebar hidden
    property bool sidebarHidden: false        // actual visual state (peeks open on h)
    function toggleSidebar() {
        sidebarCollapsed = !sidebarCollapsed
        sidebarHidden = sidebarCollapsed
        // don't leave the keyboard on a now-zero-width pane
        if (sidebarHidden && focusedPanel === "sidebar") focusPanel("messages")
    }

    function focusPanel(name) {
        // Peek a collapsed sidebar open when you move INTO it (h / Tab)…
        if (name === "sidebar" && sidebarHidden) sidebarHidden = false
        // …then collapse it again once you commit back to messages (picking a
        // channel, l, etc.) — but only if you'd toggled it off with `b`.
        if (name === "messages" && sidebarCollapsed) sidebarHidden = true
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

    function currentMode() {
        if (Backend.threadOpen) return "thread"
        if (Backend.threadsView && focusedPanel === "messages") return "threadsPage"
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
                case Qt.Key_I: return "ctrl+i"
            }
            return ""   // unmapped ctrl combo → ignore
        }
        return e.text   // j k h l g i q /
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
            "b":        { act: () => { if (win.isDiscord) win.toggleSidebar(); else browse.show() },
                          help: () => win.isDiscord ? "Toggle sidebar" : "Browse channels", cat: "chats" },
            "s":        { act: () => sidebar.toggleStarCurrent(), help: "Star / unstar channel", cat: "chats" },
            "u":        { act: () => win.openUpload(), help: "Attach a file", cat: "chats" },
            // slqs only (Discord has no equivalent): d = DM anyone, I = invite to channel.
            "d":        { act: () => { if (!Backend.railHidden) peoplePicker.showDM() }, help: () => Backend.railHidden ? "" : "Message someone", cat: "chats" },
            "I":        { act: () => { if (!Backend.railHidden) peoplePicker.showInvite() }, help: () => Backend.railHidden ? "" : "Invite to channel", cat: "chats" },
            "ctrl+k":   { act: () => palette.show(), help: "Jump palette", cat: "chats" },
            "ctrl+i":   { act: () => Backend.gotoFirstUnread(), help: "Go to first unread", cat: "chats" },
            "ctrl+s":   { act: () => workspacePicker.show(), help: () => Backend.railHidden ? "Switch server" : "Switch workspace", cat: "chats" },
            // Directional panel focus, insert-mode friendly (the composer maps the
            // same chords through panelMove). Workspace switching stays on ctrl+s.
            "ctrl+l":   { act: () => focusPanel("messages"), help: "Focus messages", cat: "nav" },
            "ctrl+h":   { act: () => focusPanel("sidebar"),  help: "Focus sidebar", cat: "nav" },
            // messages
            "i":        { act: () => { focusPanel("messages"); composer.focusInput() }, help: "Compose", cat: "msg" },
            "R":        { act: () => { if (focusedPanel === "messages") { composer.startReply(msgs.currentMessage()); focusPanel("messages") } }, help: () => Backend.hasThreads ? "Reply in thread" : "Reply to message", cat: "msg" },
            "e":        { act: () => { if (focusedPanel === "messages") { const m = msgs.currentMessage(); if (m && m.mine) composer.startEdit(m) } }, help: "Edit your message", cat: "msg" },
            "D":        { act: () => { if (focusedPanel === "messages") askDelete(msgs.currentMessage()) }, help: "Delete your message", cat: "msg" },
            "r":        { act: () => { if (focusedPanel === "messages") reactTo(msgs.currentMessage()) }, help: "React", cat: "msg" },
            "y":        { act: () => { if (focusedPanel === "messages") Backend.copyText(msgs.currentMessage()) }, help: "Copy text", cat: "msg" },
            "o":        { act: () => { if (focusedPanel === "messages") Backend.openChannelRef(msgs.currentMessage()) }, help: "Open link", cat: "msg" },
            "v":        { act: () => { if (focusedPanel === "messages") Backend.viewImage(msgs.currentMessage()) }, help: "View image", cat: "msg" },
            // views & general
            "?":        { act: () => help.show(), help: "This help", cat: "view" },
            "U":        { act: () => { if (Backend.updateAvailable) Backend.applyUpdate(); else win.uploadClipboardPath() }, help: "Upload file path from clipboard", cat: "chats" },
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
            "o":      { act: () => Backend.openChannelRef(thread.currentMessage()), help: "Open link", cat: "msg" },
            "r":      { act: () => reactTo(thread.currentMessage()), help: "React", cat: "msg" },
            "y":      { act: () => Backend.copyText(thread.currentMessage()), help: "Copy text", cat: "msg" },
            "e":      { act: () => { const m = thread.currentMessage(); if (m && m.mine) thread.startEdit(m) }, help: "Edit your message", cat: "msg" },
            "D":      { act: () => askDelete(thread.currentMessage()), help: "Delete your message", cat: "msg" },
            "ctrl+k": { act: () => palette.show(), help: "Jump palette", cat: "chats" },
            "ctrl+i": { act: () => Backend.gotoFirstUnread(), help: "Go to first unread", cat: "chats" },
            "ctrl+s": { act: () => workspacePicker.show(), help: "Switch workspace", cat: "chats" },
            "u":      { act: () => win.openUpload(), help: "Attach a file", cat: "chats" },
            "U":      { act: () => win.uploadClipboardPath(), help: "Upload file path from clipboard", cat: "chats" },
            "ctrl+h": { act: () => closeThreadAction(), help: "Back to channel", cat: "nav" },
            // thread-specific (feeds the THREADS section of the cheat sheet)
            "i":      { act: () => thread.focusReply(), help: "Reply in thread", cat: "thread" },
            "q":      { act: () => closeThreadAction(), help: "Close thread", cat: "thread" },
            "h":      { act: () => closeThreadAction(), help: "Back to channel", cat: "thread" },
            "?":      { act: () => help.show(), help: "This help", cat: "view" },
            "esc":    { act: () => closeThreadAction(), help: "Close thread", cat: "view" },
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
            "ctrl+s": { act: () => workspacePicker.show(), help: "Switch workspace", cat: "chats" },
            // threads-view specific (feeds the THREADS section)
            "enter":  { act: () => threadsPage.openCurrent(), help: "Open thread", cat: "thread" },
            "D":      { act: () => { const t = Backend.currentSubThreads[threadsPage.currentIndex]
                              if (t) { confirmUnsub.target = t; confirmUnsub.ask("#" + (t.channelName || "") + " · " + (t.title || "")) } }, help: "Unsubscribe from thread", cat: "thread" },
            "q":      { act: () => Backend.hideThreadsView(), help: "Close threads view", cat: "thread" },
            "?":      { act: () => help.show(), help: "This help", cat: "view" },
            "esc":    { act: () => Backend.hideThreadsView(), help: "Close threads view", cat: "view" },
        },
    })

    function routeKey(e) {
        const ctrl = e.modifiers & Qt.ControlModifier
        const id = keyId(e, ctrl)
        if (!id) return
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
                    onWorkspacePickerRequested: workspacePicker.show()
                }

                Item {
                    width: parent.width - sidebar.width - rail.width; height: parent.height
                    // Active panel gets the border; inactive dims slightly.
                    opacity: (win.focusedPanel === "messages" || Backend.threadOpen) ? 1.0 : 0.8
                    Behavior on opacity { NumberAnimation { duration: 120 } }

                    // focused-panel accent: full border (message pane, no thread open)
                    Rectangle {
                        id: header
                        width: parent.width; height: 52; color: "transparent"
                        Row {
                            anchors.left: parent.left; anchors.leftMargin: 18
                            anchors.verticalCenter: parent.verticalCenter; spacing: 9
                            Text { renderType: Text.NativeRendering; text: "#"; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 19 }
                            Text { renderType: Text.NativeRendering; text: Backend.currentChannel; color: Theme.fg; anchors.verticalCenter: parent.verticalCenter
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17; font.weight: 500 }
                            Rectangle { visible: Backend.currentTopic.length > 0; width: 1; height: 16; color: Theme.hairline
                                        anchors.verticalCenter: parent.verticalCenter }
                            Text { renderType: Text.NativeRendering; anchors.verticalCenter: parent.verticalCenter
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
                            Text { id: joinLbl; renderType: Text.NativeRendering; anchors.centerIn: parent
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
                            Text { renderType: Text.NativeRendering;
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
                                renderType: Text.NativeRendering
                                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13
                            }
                        }
                    }

                    ThreadsPage {
                        id: threadsPage
                        anchors.fill: parent
                        visible: Backend.threadsView
                        active: Backend.threadsView && !Backend.threadOpen
                        z: 4
                    }

                    // Clipping dock: the width springs open/closed (shared
                    // PanelMotion), but the ThreadPanel inside keeps a FIXED
                    // width — so its wrapping message text lays out once and is
                    // revealed by the clip, never reflowed/squished mid-anim.
                    Item {
                        id: threadDock
                        readonly property real openW: Math.min(560, parent.width * 0.58)
                        clip: true
                        visible: width > 1   // stay visible while it animates closed
                        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                        anchors.topMargin: 8; anchors.rightMargin: 12; anchors.bottomMargin: 12
                        width: Backend.threadOpen ? openW : 0
                        Behavior on width { PanelMotion {} }
                        z: 5
                        ThreadPanel {
                            id: thread
                            width: threadDock.openW
                            anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                            onExitReply: win.backToNormal()
                            onOpenPalette: palette.show()
                            // H = back to the channel (closes the thread panel); L = rightmost, just normal mode.
                            onPanelMove: (d) => { if (d < 0) win.closeThreadAction(); else win.backToNormal() }
                        }
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
                        Text { renderType: Text.NativeRendering;
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
                    Text { renderType: Text.NativeRendering;
                        anchors.verticalCenter: parent.verticalCenter
                        text: "panel: " + win.focusedPanel + "   #" + Backend.currentChannel
                              + (win.pendingCount > 0 ? "      " + win.pendingCount : "")
                        color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12
                    }
                }
                // Persistent help affordance — stays pinned in the corner even
                // when the rest of the hints collapse on a narrow window.
                StatusCap {
                    id: helpBadge
                    visible: !Backend.updateAvailable
                    text: "?"
                    anchors.right: parent.right; anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
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
                    StatusCap { text: "⌃k" }
                    CapLabel { text: "jump" }
                    Item { width: 8; height: 1 }
                    StatusCap { text: "j" }
                    StatusCap { text: "k" }
                    CapLabel { text: "move" }
                    Item { width: 8; height: 1 }
                    StatusCap { text: "h" }
                    StatusCap { text: "l" }
                    CapLabel { text: "panel" }
                    Item { width: 8; height: 1 }
                    StatusCap { text: "↵" }
                    CapLabel { text: "open" }
                    Item { width: 8; height: 1 }
                    StatusCap { text: "i" }
                    CapLabel { text: "insert" }
                    Item { width: 8; height: 1 }
                    StatusCap { text: "esc" }
                    CapLabel { text: "normal" }
                }
                Text { renderType: Text.NativeRendering;
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

            KeybindHelp {
                id: help
                z: 103
                keymaps: win.keymaps
                onOpenChanged: if (!open) win.backToNormal()
            }

            // Transient status toast (e.g. "Copied message"), fired by Backend.toast().
            Rectangle {
                id: toast
                z: 200
                property string message: ""
                visible: opacity > 0
                opacity: 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom; anchors.bottomMargin: 30
                width: toastLbl.implicitWidth + 28; height: 32; radius: 8
                color: Theme.surface; border.width: 1; border.color: Theme.hairline
                Behavior on opacity { NumberAnimation { duration: 140 } }
                Text {
                    id: toastLbl; renderType: Text.NativeRendering; anchors.centerIn: parent
                    text: toast.message; color: Theme.fg
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13
                }
                Timer { id: toastTimer; interval: 1400; onTriggered: toast.opacity = 0 }
                Connections {
                    target: Backend
                    function onToast(message) { toast.message = message; toast.opacity = 1; toastTimer.restart() }
                }
            }

        }
    }

    Component.onCompleted: { focusPanel("sidebar"); console.log("PROTO_READY") }
}
