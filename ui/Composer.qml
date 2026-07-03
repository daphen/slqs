import QtQuick
import QtQuick.Controls
import "."

Rectangle {
    id: root
    readonly property bool attaching: Backend.attachState !== "none"
    readonly property bool replying: replyTs !== "" || editingTs !== ""
    // Grow with the text, capped at 180px; a single line's natural implicitHeight
    // is the minimum (no artificial floor). Matches the thread reply input.
    implicitHeight: Math.min(180, input.implicitHeight + 26 + ((attaching || replying) ? 26 : 0))
    radius: Theme.radius
    color: Theme.surface
    border.color: input.focus ? Theme.cursor : Theme.hairline
    border.width: 1
    Behavior on border.color { ColorAnimation { duration: 120 } }

    signal exitInsert()
    signal openPalette()   // Ctrl+K from insert mode → jump palette (drops to normal)
    signal pageScroll(int d)   // Ctrl+D/U from insert mode → drop to normal + half-page scroll
    signal panelMove(int d)    // Ctrl+H/L from insert mode → drop to normal + focus panel left/right
    // `focus` (not `activeFocus`): the input keeps focus when the window is
    // backgrounded, so insert mode (and the hidden line numbers) persist instead
    // of snapping back to normal mode just because you switched apps.
    property alias inputHasFocus: input.focus
    property string editingTs: ""   // non-empty while editing an existing message
    property string replyTs: ""     // non-empty while replying to a message
    property string replyAuthor: ""
    function focusInput() { input.forceActiveFocus() }
    function send() {
        if (editingTs !== "") { Backend.editMessage(editingTs, input.text); editingTs = "" }
        else if (replyTs !== "") { Backend.sendReplyTo(replyTs, input.text); replyTs = ""; replyAuthor = "" }
        else Backend.sendMessage(input.text)
        input.clear()
        ac.reset()
    }
    // `e` on a focused message → load it for editing.
    function startEdit(msg) {
        if (!msg || !msg.ts) return
        replyTs = ""; editingTs = msg.ts
        input.text = Backend.plainText(msg.text)
        input.cursorPosition = input.text.length
        input.forceActiveFocus()
    }
    // `R` on a focused message → reply to it (Discord reply / Slack thread reply).
    function startReply(msg) {
        if (!msg || !msg.ts) return
        editingTs = ""; replyTs = msg.ts; replyAuthor = msg.author || ""
        input.forceActiveFocus()
    }
    function cancelEdit() { editingTs = ""; replyTs = ""; replyAuthor = ""; input.clear() }

    // shared `:` emoji + `@` mention autocomplete (popup floats above the box)
    Autocomplete { id: ac; anchors.fill: parent; input: input }

    Connections {
        target: Backend
        function onPasteFallback() { if (input.activeFocus) input.paste() }
    }

    // reply / edit context chip — stays visible even with a draft typed (the
    // placeholder hides once you type, so this is the durable "Replying to …" badge)
    Row {
        id: replyChip
        visible: root.replying
        anchors.left: parent.left; anchors.leftMargin: 14
        anchors.top: parent.top; anchors.topMargin: 8
        spacing: 6
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
               text: root.editingTs !== "" ? "✎  Editing message" : ("↰  Replying to " + root.replyAuthor)
               color: Theme.fg
               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13 }
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
               text: "  ✕"; color: Theme.fg_muted
               font.family: Theme.fontFamily; font.pixelSize: 13
               TapHandler { onTapped: { if (root.editingTs !== "") root.cancelEdit(); else { root.replyTs = ""; root.replyAuthor = "" } } } }
    }

    // staged-attachment chip + upload progress (Ctrl+V → attach; Enter sends it).
    // Sits below the reply/edit chip when both are showing.
    Row {
        id: attachChip
        visible: root.attaching
        // sit to the right of the reply chip when both are showing, else at the edge
        anchors.left: root.replying ? replyChip.right : parent.left
        anchors.leftMargin: root.replying ? 16 : 14
        anchors.top: parent.top; anchors.topMargin: 8
        spacing: 6
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; text: "📎"; anchors.verticalCenter: parent.verticalCenter
               font.family: Theme.fontFamily; font.pixelSize: 13 }
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
               text: Backend.attachState === "uploading" ? "uploading image…" : (Backend.attachName || "image")
               color: Backend.attachState === "uploading" ? Theme.fg_muted : Theme.fg
               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13 }
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
               text: Backend.attachState === "ready" ? "✓" : ""; color: Theme.green
               font.family: Theme.fontFamily; font.pixelSize: 13 }
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
               text: "  ✕"; color: Theme.fg_muted
               font.family: Theme.fontFamily; font.pixelSize: 13
               TapHandler { onTapped: Backend.dropAttach() } }
    }

    Flickable {
        id: flick
        anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                  leftMargin: 14; rightMargin: 50; topMargin: 12 + ((root.attaching || root.replying) ? 24 : 0); bottomMargin: 12 }
        contentHeight: input.implicitHeight; clip: true
        // keep the cursor in view once the text grows past the visible cap
        function ensureVisible(r) {
            if (contentY >= r.y) contentY = r.y
            else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
        }
        TextArea { renderType: TextArea.QtRendering;
            id: input
            width: flick.width
            onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)
            wrapMode: TextArea.Wrap
            color: Theme.fg
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 15
            placeholderText: root.editingTs !== "" ? "Editing message… (Esc to cancel)"
                           : root.replyTs !== "" ? "Replying to " + root.replyAuthor + "… (Esc to cancel)"
                           : "Message #" + Backend.currentChannel
            placeholderTextColor: Theme.fg_muted
            background: null
            onTextChanged: { ac.update(); if (text.length > 0) Backend.notifyTyping() }
            onCursorPositionChanged: ac.update()
            Keys.onPressed: e => {
                // Ctrl+V routes through the daemon: image → attach, else pasteFallback
                // pastes text. Accepted so an image+text clipboard doesn't double-paste.
                if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_V) {
                    Backend.pasteImage(); e.accepted = true; return
                }
                // Ctrl+E: edit the last message you sent in this channel.
                if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_E) {
                    const m = Backend.lastMineInChannel(); if (m) root.startEdit(m)
                    e.accepted = true; return
                }
                // Ctrl+K: the jump palette also opens from insert mode (it grabs
                // focus, so you drop to normal mode, and stay there when it closes).
                if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_K) {
                    root.openPalette(); e.accepted = true; return
                }
                // Ctrl+D/U: drop to normal mode and half-page scroll the chat.
                if ((e.modifiers & Qt.ControlModifier) && (e.key === Qt.Key_D || e.key === Qt.Key_U)) {
                    root.exitInsert(); root.pageScroll(e.key === Qt.Key_D ? 1 : -1)
                    e.accepted = true; return
                }
                // Ctrl+H/L: drop to normal mode and focus the panel in that direction.
                if ((e.modifiers & Qt.ControlModifier) && (e.key === Qt.Key_H || e.key === Qt.Key_L)) {
                    root.exitInsert(); root.panelMove(e.key === Qt.Key_H ? -1 : 1)
                    e.accepted = true; return
                }
                if (ac.handleKey(e)) { e.accepted = true; return }
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                    if (e.modifiers & Qt.ShiftModifier) { e.accepted = false }
                    else { root.send(); e.accepted = true }
                    return
                }
                if (e.key === Qt.Key_Escape) {
                    if (root.attaching) Backend.dropAttach()
                    // Leave insert but KEEP the draft — so you can navigate up, press R
                    // on a message, and send it as a reply. An in-progress edit discards
                    // (Esc-cancel); a reply just drops its target, keeping what you typed.
                    if (root.editingTs !== "") root.cancelEdit()
                    else { root.replyTs = ""; root.replyAuthor = "" }
                    root.exitInsert(); e.accepted = true
                }
            }
        }
    }

    // send button
    Rectangle {
        anchors.right: parent.right; anchors.rightMargin: 8
        anchors.bottom: parent.bottom; anchors.bottomMargin: 8
        width: 32; height: 32; radius: Theme.radiusSm
        readonly property bool on: input.text.trim().length > 0
        color: on ? Theme.cursor : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.06)
        Behavior on color { ColorAnimation { duration: 120 } }
        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.centerIn: parent; text: "➤"
               color: parent.on ? Theme.ink : Theme.fg_muted
               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 15 }
        TapHandler { onTapped: root.send() }
    }
}
