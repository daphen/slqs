import QtQuick
import QtQuick.Controls
import "."

// Right-hand thread panel: parent message + replies, with a reply composer.
// Opened by Enter on a message; closed with q (handled in shell's key router).
Rectangle {
    id: panel
    color: Theme.bg
    topLeftRadius: 10     // card edges over the channel (right side meets the window)
    bottomLeftRadius: 10
    signal exitReply()
    signal openPalette()   // Ctrl+K from the reply input → jump palette (drops to normal)
    signal panelMove(int d)   // Ctrl+H/L from the reply input → drop to normal + panel left/right
    property bool alsoToChannel: false   // Slack "also send to channel" (thread broadcast); reset after each send

    function focusReply() { replyInput.forceActiveFocus() }
    property string editingTs: ""   // editing an existing reply
    function startEdit(msg) {
        if (!msg || !msg.ts) return
        editingTs = msg.ts
        replyInput.text = Backend.plainText(msg.text)
        replyInput.cursorPosition = replyInput.text.length
        replyInput.forceActiveFocus()
    }
    // j/k move a per-message cursor (like the main pane), not just scroll.
    function move(d) {
        tlist.justOpened = false
        tlist.currentIndex = Math.max(0, Math.min(tlist.count - 1, tlist.currentIndex + d))
        if (tlist.currentIndex >= tlist.count - 1) tlist.positionViewAtEnd()
        else tlist.positionViewAtIndex(tlist.currentIndex, ListView.Contain)
        // Follow the bottom while the cursor is on the last reply, so a reaction
        // there (or new content) re-pins; release it the moment you move up.
        tlist.pinEnd = (tlist.currentIndex >= tlist.count - 1)
    }
    function currentMessage() { return (tlist.currentIndex >= 0 && tlist.currentIndex < tlist.count) ? Backend.thread.get(tlist.currentIndex) : null }
    // ctrl+e / ctrl+y: nudge the thread view without moving the cursor.
    function scroll(d) {
        const maxY = Math.max(0, tlist.contentHeight - tlist.height)
        tlist.contentY = Math.max(0, Math.min(maxY, tlist.contentY + d * 48))
        tlist.pinEnd = tlist.atYEnd
    }
    // `focus` (not `activeFocus`): the reply keeps focus when the window is
    // backgrounded, so thread insert mode persists across an app switch.
    property alias replyHasFocus: replyInput.focus

    // Opening a thread shows the parent (the message that spawned it) at the top.
    // Replies load a beat later; justOpened keeps the view at the top through that
    // first populate, then releases so new replies don't yank it around.
    Connections {
        target: Backend
        function onThreadParentTsChanged() {
            if (Backend.threadParentTs === "") return
            // From the Threads view (catching up replies) → land on the latest.
            // From a channel message (you clicked the root) → start at the parent.
            if (Backend.threadOpenToLatest) {
                tlist.justOpened = false; tlist.pinEnd = true; Qt.callLater(tlist.toEnd)
            } else {
                tlist.pinEnd = false; tlist.justOpened = true; Qt.callLater(tlist.toTop)
            }
        }
    }

    // focused-panel accent: full border (the thread panel has focus while open)
    Rectangle {
        anchors.fill: parent; z: 10
        color: "transparent"
        topRightRadius: 10   // window-edge corner
        topLeftRadius: 10    // card edge over the channel
        bottomLeftRadius: 10
        border.width: 2
        // orange while typing a reply in this panel (insert mode)
        border.color: replyInput.focus ? Theme.cursor : Theme.fg
    }

    Rectangle {
        id: thHeader
        anchors.top: parent.top; width: parent.width; height: 52; color: Theme.bg
        topLeftRadius: 10   // follow the panel's rounded top-left corner
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
        Row {
            anchors.left: parent.left; anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter; spacing: 8
            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; text: "Thread"; color: Theme.fg
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 16; font.weight: 600 }
            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; text: "— " + Backend.threadTitle; color: Theme.fg_muted
                   anchors.verticalCenter: parent.verticalCenter
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14 }
        }
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality;
            anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
            text: "q to close"; color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12
        }
    }

    ListView {
        id: tlist
        anchors.top: thHeader.bottom; anchors.bottom: thTypingRow.top; width: parent.width
        clip: true; cacheBuffer: 1000000; topMargin: 6; bottomMargin: 8
        boundsBehavior: Flickable.StopAtBounds
        model: Backend.thread
        delegate: MessageDelegate { inThread: true }
        // the delegate's cursor highlight shows when its ListView is "active";
        // the thread list is active whenever the panel is open and not replying.
        property bool active: Backend.threadOpen && !panel.replyHasFocus
        property bool showNumbers: active   // thread numbers follow the same normal-mode rule
        highlightFollowsCurrentItem: false

        property bool pinEnd: false     // follow the latest reply only after the user scrolls there
        property bool justOpened: false  // keep the parent at the top through the initial reply load
        function toEnd() {
            if (count <= 0) return
            currentIndex = count - 1; positionViewAtEnd()
            contentY = Math.max(0, contentHeight - height); returnToBounds()   // true bottom (incl. margin)
        }
        function toTop() { if (count > 0) { currentIndex = 0; positionViewAtBeginning() } }
        // Re-pin to the bottom when a message grows (reaction added) or the
        // viewport shrinks (typing row) — not just on new replies.
        onContentHeightChanged: if (!justOpened && pinEnd) Qt.callLater(toEnd)
        onCountChanged: Qt.callLater(function() {
            if (justOpened) { toTop(); justOpened = false }
            else if (pinEnd) toEnd()
        })
        // Follow the latest reply while you're at the bottom (chatting); stop
        // following the moment you scroll up, so you're not yanked around.
        onMovementEnded: if (!justOpened) pinEnd = atYEnd
        // When the viewport shrinks (the typing row appears above the footer),
        // re-pin so the latest message stays visible instead of sliding under it.
        onHeightChanged: if (pinEnd && !justOpened) Qt.callLater(toEnd)

        WheelHandler {
            acceptedDevices: PointerDevice.TouchPad | PointerDevice.Mouse
            onWheel: e => {
                const px = (e.pixelDelta.y !== 0) ? e.pixelDelta.y : e.angleDelta.y / 8
                tlist.contentY = tlist.contentY - px * 5
                tlist.returnToBounds()
                tlist.pinEnd = tlist.atYEnd
                e.accepted = true
            }
        }
        ScrollBar.vertical: ScrollBar { width: 8; policy: ScrollBar.AsNeeded }
    }

    // Typing indicator for the thread (someone typing a reply in this thread).
    Item {
        id: thTypingRow
        anchors.bottom: thFooter.top; width: parent.width
        height: Backend.threadTyping ? 22 : 0
        clip: true
        Behavior on height { NumberAnimation { duration: 120 } }
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; x: 16
               anchors.top: parent.top; anchors.bottom: parent.bottom; verticalAlignment: Text.AlignVCenter
               text: Backend.threadTypingWho + " is typing…"; color: Theme.fg_muted
               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13 }
    }

    Rectangle {
        id: thFooter
        anchors.bottom: parent.bottom; width: parent.width; color: Theme.bg
        bottomLeftRadius: 10   // follow the panel's rounded bottom-left corner
        // Grow with the text, capped at 180px (then the Flickable scrolls). +36 is box
        // chrome; bcastH reserves the "Also send to channel" toggle row above the box.
        readonly property real bcastH: panel.editingTs === "" ? 24 : 0
        height: bcastH + Math.min(180, replyInput.implicitHeight + 36)
        // Slack thread-broadcast. Click to toggle; Ctrl+Enter on send does it one-off.
        // Hidden while editing an existing reply.
        Row {
            id: bcastRow
            anchors.top: parent.top; anchors.left: parent.left
            anchors.leftMargin: 14; anchors.topMargin: 8
            spacing: 6; visible: thFooter.bcastH > 0
            Rectangle {
                width: 14; height: 14; radius: 3; anchors.verticalCenter: parent.verticalCenter
                color: panel.alsoToChannel ? Theme.cursor : "transparent"
                border.color: panel.alsoToChannel ? Theme.cursor : Theme.hairline; border.width: 1
                Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.centerIn: parent; visible: panel.alsoToChannel
                       text: "✓"; color: Theme.ink; font.pixelSize: 10; font.weight: 800 }
            }
            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
                   text: "Also send to channel"; color: panel.alsoToChannel ? Theme.fg : Theme.fg_muted
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12 }
            TapHandler { onTapped: panel.alsoToChannel = !panel.alsoToChannel }
        }
        Rectangle {
            anchors.fill: parent; anchors.margins: 10; anchors.topMargin: 10 + thFooter.bcastH; radius: Theme.radius
            color: Theme.surface; border.width: 1
            border.color: replyInput.focus ? Theme.cursor : Theme.hairline
            // same `:` emoji + `@` mention autocomplete as the channel composer
            Autocomplete { id: replyAc; anchors.fill: parent; input: replyInput }
            Connections {
                target: Backend
                function onPasteFallback() { if (replyInput.activeFocus) replyInput.paste() }
            }
            // Top-anchored Flickable + content-sized TextArea (mirrors Composer):
            // the box grows with the text and a single line sits aligned instead
            // of pinned to the top of a fixed-height field.
            Flickable {
                id: replyFlick
                anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                          leftMargin: 12; rightMargin: 12; topMargin: 8; bottomMargin: 8 }
                contentHeight: replyInput.implicitHeight; clip: true
                function ensureVisible(r) {
                    if (contentY >= r.y) contentY = r.y
                    else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
                }
            TextArea { renderType: TextArea.QtRendering;
                id: replyInput
                width: replyFlick.width
                onCursorRectangleChanged: replyFlick.ensureVisible(cursorRectangle)
                wrapMode: TextArea.Wrap; color: Theme.fg
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 15
                placeholderText: panel.editingTs !== "" ? "Editing… (Esc to cancel)" : "Reply…"
                placeholderTextColor: Theme.fg_muted
                background: null
                onTextChanged: { replyAc.update(); if (text.length > 0) Backend.notifyTyping() }
                onCursorPositionChanged: replyAc.update()
                Keys.onPressed: e => {
                    if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_V) {
                        Backend.pasteImage(Backend.threadParentTs); e.accepted = true; return
                    }
                    // Ctrl+E: edit the last message you sent in this thread.
                    if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_E) {
                        const m = Backend.lastMineInThread(); if (m) panel.startEdit(m)
                        e.accepted = true; return
                    }
                    // Ctrl+K: jump palette from the reply input too (drops to normal).
                    if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_K) {
                        panel.openPalette(); e.accepted = true; return
                    }
                    // Ctrl+D/U: drop to normal mode and scroll the thread.
                    if ((e.modifiers & Qt.ControlModifier) && (e.key === Qt.Key_D || e.key === Qt.Key_U)) {
                        panel.exitReply(); panel.move(e.key === Qt.Key_D ? 8 : -8)
                        e.accepted = true; return
                    }
                    // Ctrl+H/L: drop to normal mode; H moves left (back to the channel).
                    if ((e.modifiers & Qt.ControlModifier) && (e.key === Qt.Key_H || e.key === Qt.Key_L)) {
                        panel.exitReply(); panel.panelMove(e.key === Qt.Key_H ? -1 : 1)
                        e.accepted = true; return
                    }
                    if (replyAc.handleKey(e)) { e.accepted = true; return }
                    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                        if (e.modifiers & Qt.ShiftModifier) { e.accepted = false }
                        else {
                            // Ctrl+Enter forces "also send to channel" even if the toggle is off.
                            const bcast = panel.alsoToChannel || !!(e.modifiers & Qt.ControlModifier)
                            if (panel.editingTs !== "") { Backend.editMessage(panel.editingTs, text); panel.editingTs = "" }
                            else Backend.sendThreadReply(text, bcast)
                            panel.alsoToChannel = false
                            // follow to the bottom so your reply (and the echo) lands in view
                            tlist.pinEnd = true; Qt.callLater(tlist.toEnd)
                            clear(); replyAc.reset(); e.accepted = true
                        }
                        return
                    }
                    if (e.key === Qt.Key_Escape) { if (panel.editingTs !== "") { panel.editingTs = ""; clear() } panel.exitReply(); e.accepted = true }
                }
            }
            }
        }
    }
}
