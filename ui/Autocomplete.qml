import QtQuick
import "."

// Inline ':' emoji + '@' mention autocomplete for a TextArea. Place it filling
// the input's container (the popup floats just above that container) and set
// `input` to the TextArea. The host wires: onTextChanged/onCursorPositionChanged
// → ac.update(); Keys.onPressed → if (ac.handleKey(e)) consume.
Item {
    id: ac
    property var input
    property string mode: ""   // "" | "emoji" | "user"
    property int startPos: -1
    property var rows: []
    property int sel: 0
    readonly property bool active: mode !== "" && rows.length > 0

    function reset() { mode = ""; rows = [] }
    function move(d) { if (rows.length) sel = Math.max(0, Math.min(rows.length - 1, sel + d)) }

    // Find the token under the cursor; open/refresh if it starts with : or @
    // (trigger at line start or after whitespace).
    function update() {
        if (!input) return
        const pos = input.cursorPosition, txt = input.text
        let i = pos - 1
        while (i >= 0) {
            const ch = txt[i]
            if (ch === ":" || ch === "@") {
                if (i === 0 || /\s/.test(txt[i - 1])) {
                    const token = txt.substring(i + 1, pos)
                    // emoji needs >= 2 chars after ':' (":jo" yes, ":p" no — too noisy);
                    // mentions ('@') open immediately.
                    if (/^[A-Za-z0-9_+'.\-]*$/.test(token) && (ch === "@" || token.length >= 2)) {
                        mode = ch === ":" ? "emoji" : "user"
                        startPos = i
                        rows = mode === "emoji" ? Backend.searchEmoji(token.toLowerCase(), 8)
                                                : Backend.searchUsers(token.toLowerCase(), 8)
                        sel = 0
                        return
                    }
                }
                break
            }
            if (/\s/.test(ch)) break
            i--
        }
        reset()
    }
    function accept() {
        const r = rows[sel]
        if (!r) { reset(); return }
        let insert
        if (mode === "emoji") { insert = r.custom ? (":" + r.name + ":") : r.glyph; Backend.recordEmojiUse(r.name) }
        else { insert = "@" + r.name + " "; Backend.registerMention(r.name, r.id) }
        const before = input.text.substring(0, startPos)
        const after = input.text.substring(input.cursorPosition)
        input.text = before + insert + after
        input.cursorPosition = (before + insert).length
        reset()
    }
    // Returns true if it consumed the key (host should set e.accepted).
    function handleKey(e) {
        if (mode === "") return false
        switch (e.key) {
            case Qt.Key_Down: move(1); return true
            case Qt.Key_Up:   move(-1); return true
            case Qt.Key_Tab:  accept(); return true
            case Qt.Key_Return: case Qt.Key_Enter: accept(); return true
            case Qt.Key_Escape: reset(); return true
        }
        if (e.modifiers & Qt.ControlModifier) {
            if (e.key === Qt.Key_J) { move(1); return true }
            if (e.key === Qt.Key_K) { move(-1); return true }
        }
        return false
    }

    Rectangle {
        visible: ac.active
        anchors.left: parent.left; anchors.bottom: parent.top; anchors.bottomMargin: 6
        width: 340
        height: visible ? Math.min(acList.contentHeight + 8, 248) : 0
        color: Theme.bg_alt; radius: Theme.radius
        border.color: Theme.hairline; border.width: 1
        ListView {
            id: acList
            anchors.fill: parent; anchors.margins: 4; clip: true
            model: ac.rows; currentIndex: ac.sel
            highlightFollowsCurrentItem: false
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            delegate: Rectangle {
                id: arow
                required property var modelData
                required property int index
                width: acList.width; height: 32
                color: index === ac.sel ? Theme.selection : ahov.hovered ? Theme.hover : "transparent"
                Row {
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 9
                    Item {
                        width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter
                        visible: ac.mode === "emoji"
                        Image { anchors.fill: parent; visible: !!arow.modelData.custom; source: arow.modelData.path || ""
                                fillMode: Image.PreserveAspectFit; sourceSize.width: 40; sourceSize.height: 40 }
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.centerIn: parent; visible: !arow.modelData.custom
                               text: arow.modelData.glyph || ""; font.pixelSize: 18 }
                    }
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
                           text: ac.mode === "emoji" ? (":" + arow.modelData.name + ":") : ("@" + arow.modelData.name)
                           color: Theme.fg
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14 }
                }
                HoverHandler { id: ahov }
                TapHandler { onTapped: { ac.sel = arow.index; ac.accept(); if (ac.input) ac.input.forceActiveFocus() } }
            }
        }
    }
}
