import QtQuick
import QtQuick.Window
import Quickshell
import "."

FloatingWindow {
    id: win
    implicitWidth: 1180
    implicitHeight: 760
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

    function focusPanel(name) {
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
        else if (focusedPanel === "messages" && Backend.hasThreads) { const m = msgs.currentMessage(); if (m) Backend.openThread(m) }
    }
    function backToNormal() { appRoot.forceActiveFocus() }

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
            }
            return ""   // unmapped ctrl combo → ignore
        }
        return e.text   // j k h l g i q /
    }

    readonly property var keymaps: ({
        "channel": {
            "ctrl+k":   () => palette.show(),
            "ctrl+s":   () => workspacePicker.show(),
            "esc":      () => backToNormal(),
            "tab":      () => cyclePanel(1),
            "shift+tab":() => cyclePanel(-1),
            "enter":    () => activate(),
            "ctrl+d":   () => halfPage(1),
            "ctrl+u":   () => halfPage(-1),
            "ctrl+e":   () => scrollView(1),
            "ctrl+y":   () => scrollView(-1),
            "ctrl+g":   () => goBottom(),
            "G":        () => goBottom(),
            "j":        () => moveCursor(1),
            "k":        () => moveCursor(-1),
            "h":        () => focusPanel("sidebar"),
            "l":        () => focusPanel("messages"),
            "g":        () => goTop(),
            // typing composes to the open channel → make the chat the active panel
            "i":        () => { focusPanel("messages"); composer.focusInput() },
            "v":        () => { if (focusedPanel === "messages") Backend.viewImage(msgs.currentMessage()) },
            "o":        () => { if (focusedPanel === "messages") Backend.openChannelRef(msgs.currentMessage()) },
            "r":        () => { if (focusedPanel === "messages") reactTo(msgs.currentMessage()) },
            "R":        () => { if (focusedPanel === "messages") { composer.startReply(msgs.currentMessage()); focusPanel("messages") } },
            "y":        () => { if (focusedPanel === "messages") Backend.copyText(msgs.currentMessage()) },
            "e":        () => { if (focusedPanel === "messages") composer.startEdit(msgs.currentMessage()) },
            "D":        () => { if (focusedPanel === "messages") askDelete(msgs.currentMessage()) },
            "b":        () => browse.show(),
            "ctrl+l":   () => Backend.cycleWorkspace(1),
            "ctrl+h":   () => Backend.cycleWorkspace(-1),
            "/":        () => sidebar.focusSearch(),
        },
        "thread": {
            "ctrl+k": () => palette.show(),
            "ctrl+s": () => workspacePicker.show(),
            "q":      () => closeThreadAction(),
            "esc":    () => closeThreadAction(),
            "h":      () => closeThreadAction(),   // back out to the channel
            "i":      () => thread.focusReply(),
            "ctrl+d": () => thread.move(8),
            "ctrl+u": () => thread.move(-8),
            "ctrl+e": () => thread.scroll(1),
            "ctrl+y": () => thread.scroll(-1),
            "ctrl+g": () => thread.move(9999),
            "G":      () => thread.move(9999),    // bottom of thread
            "g":      () => thread.move(-9999),   // top of thread
            "ctrl+l": () => Backend.cycleWorkspace(1),
            "ctrl+h": () => Backend.cycleWorkspace(-1),
            "v":      () => Backend.viewImage(thread.currentMessage()),
            "o":      () => Backend.openChannelRef(thread.currentMessage()),
            "r":      () => reactTo(thread.currentMessage()),
            "y":      () => Backend.copyText(thread.currentMessage()),
            "e":      () => thread.startEdit(thread.currentMessage()),
            "D":      () => askDelete(thread.currentMessage()),
            "j":      () => thread.move(1),
            "k":      () => thread.move(-1),
        },
        "threadsPage": {
            "ctrl+k": () => palette.show(),
            "ctrl+s": () => workspacePicker.show(),
            "q":      () => Backend.hideThreadsView(),
            "esc":    () => Backend.hideThreadsView(),
            "h":      () => focusPanel("sidebar"),
            "enter":  () => threadsPage.openCurrent(),
            "ctrl+d": () => threadsPage.half(1),
            "ctrl+u": () => threadsPage.half(-1),
            "ctrl+g": () => threadsPage.toBottom(),
            "G":      () => threadsPage.toBottom(),
            "j":      () => threadsPage.move(1),
            "k":      () => threadsPage.move(-1),
            "g":      () => threadsPage.toTop(),
            "D":      () => { const t = Backend.currentSubThreads[threadsPage.currentIndex]
                              if (t) { confirmUnsub.target = t; confirmUnsub.ask("#" + (t.channelName || "") + " · " + (t.title || "")) } },
        },
    })

    function routeKey(e) {
        const ctrl = e.modifiers & Qt.ControlModifier
        const id = keyId(e, ctrl)
        if (!id) return
        // numeric count prefix (for j/k jumps like 15k); 0 only extends a count
        if (!ctrl && id.length === 1 && id >= "0" && id <= "9") {
            if (id !== "0" || pendingCount > 0) {
                pendingCount = pendingCount * 10 + parseInt(id)
                e.accepted = true
                return
            }
        }
        const fn = keymaps[currentMode()][id]
        if (fn) { fn(); e.accepted = true }
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
            color: Theme.bg

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
                    width: 240; height: parent.height
                    onSearchClosed: win.backToNormal()
                    onThreadsClicked: { Backend.showThreadsView(); win.focusPanel("messages") }
                    onWorkspacePickerRequested: workspacePicker.show()
                }

                Item {
                    width: parent.width - 240 - rail.width; height: parent.height
                    // Active panel gets the border; inactive dims slightly.
                    opacity: (win.focusedPanel === "messages" || Backend.threadOpen) ? 1.0 : 0.8
                    Behavior on opacity { NumberAnimation { duration: 120 } }

                    // focused-panel accent: full border (message pane, no thread open)
                    Rectangle {
                        anchors.fill: parent; z: 10
                        color: "transparent"
                        topRightRadius: 10   // only the window-edge corner; the left edge is internal
                        border.width: 2
                        // orange while typing in this panel (insert mode), else the normal accent
                        border.color: composer.inputHasFocus ? Theme.cursor : Theme.fg
                        visible: win.focusedPanel === "messages" && !Backend.threadOpen
                    }

                    Rectangle {
                        id: header
                        width: parent.width; height: 52; color: Theme.bg
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
                        Row {
                            anchors.left: parent.left; anchors.leftMargin: 18
                            anchors.verticalCenter: parent.verticalCenter; spacing: 9
                            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; text: "#"; color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 19 }
                            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; text: Backend.currentChannel; color: Theme.fg; anchors.verticalCenter: parent.verticalCenter
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 17; font.weight: 700 }
                            Rectangle { visible: Backend.currentTopic.length > 0; width: 1; height: 16; color: Theme.hairline
                                        anchors.verticalCenter: parent.verticalCenter }
                            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
                                   // collapse the (often multi-line) topic to one elided line
                                   text: Backend.currentTopic.replace(/[\r\n]+/g, "  ")
                                   color: Theme.fg_muted; elide: Text.ElideRight
                                   maximumLineCount: 1; wrapMode: Text.NoWrap
                                   width: Math.max(0, header.width - 240)
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14 }
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
                            Text { id: joinLbl; renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.centerIn: parent
                                   text: "+ Join channel"; color: Theme.sky
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13; font.weight: 700 }
                            MouseArea { id: joinMA; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: Backend.joinCurrent() }
                        }
                    }

                    MessageList {
                        id: msgs
                        anchors.top: header.bottom; anchors.bottom: footer.top
                        anchors.bottomMargin: 10
                        width: parent.width
                        // Highlight stays in insert mode only when targeting a specific
                        // message (reply/edit); numbers show in normal mode only.
                        active: win.focusedPanel === "messages" && !Backend.threadOpen
                                && (!win.insertMode || composer.replyTs !== "" || composer.editingTs !== "")
                        showNumbers: win.focusedPanel === "messages" && !Backend.threadOpen && !win.insertMode
                    }

                    Item {
                        id: footer
                        width: parent.width
                        anchors.bottom: parent.bottom
                        height: composer.height + typingRow.height + 16

                        Item {
                            id: typingRow
                            width: parent.width; anchors.top: parent.top
                            height: Backend.typing ? 22 : 0
                            clip: true
                            Behavior on height { NumberAnimation { duration: 120 } }
                            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality;
                                x: 20; anchors.top: parent.top; anchors.bottom: parent.bottom
                                verticalAlignment: Text.AlignVCenter
                                text: Backend.typingWho + " is typing…"
                                color: Theme.fg_muted
                                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13
                            }
                        }

                        Composer {
                            id: composer
                            anchors.top: typingRow.bottom; anchors.topMargin: 2
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.leftMargin: 16; anchors.rightMargin: 16
                            onExitInsert: win.backToNormal()
                            onOpenPalette: palette.show()
                            // Clicking into the composer makes the messages panel the
                            // focused one, so the state machine is in sync on Esc.
                            onInputHasFocusChanged: if (inputHasFocus) win.focusPanel("messages")
                        }
                    }

                    ThreadsPage {
                        id: threadsPage
                        anchors.fill: parent
                        visible: Backend.threadsView
                        active: Backend.threadsView && !Backend.threadOpen
                        z: 4
                    }

                    ThreadPanel {
                        id: thread
                        visible: Backend.threadOpen
                        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                        width: Math.min(480, parent.width * 0.52)
                        z: 5
                        onExitReply: win.backToNormal()
                        onOpenPalette: palette.show()
                    }
                }
            }

            // ── statusbar (vim-style) ──────────────────────────────────────
            Rectangle {
                id: statusbar
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                // Footer cohesive with the sidebar (bg_alt) in both themes,
                // divided by the hairline rather than a heavy block.
                height: 22; color: Theme.bg_alt
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.hairline }
                Row {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    spacing: 0
                    Rectangle {
                        width: modeLabel.implicitWidth + 18; height: 22
                        color: win.insertMode ? Theme.cursor : Theme.green
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality;
                            id: modeLabel; anchors.centerIn: parent
                            text: win.insertMode ? "INSERT" : "NORMAL"
                            // Contrast against the chip's own bg: dark text on a light
                            // chip (dark-mode green / orange), light text on a dark chip
                            // (light-mode green) — fixes dark-on-dark-green in light mode.
                            color: (parent.color.r * 0.299 + parent.color.g * 0.587 + parent.color.b * 0.114) > 0.5 ? Theme.ink : Theme.brightWhite
                            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                            font.pixelSize: 12; font.weight: 800
                        }
                    }
                    Item { width: 10; height: 1 }
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality;
                        anchors.verticalCenter: parent.verticalCenter
                        text: "panel: " + win.focusedPanel + "   #" + Backend.currentChannel
                              + (win.pendingCount > 0 ? "      " + win.pendingCount : "")
                        color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12
                    }
                }
                Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality;
                    anchors.right: parent.right; anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: "ctrl+k jump · j/k move · h/l panel · ⏎ open · i insert · esc normal"
                    color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12
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
                    id: toastLbl; renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.centerIn: parent
                    text: toast.message; color: Theme.fg
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13
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
