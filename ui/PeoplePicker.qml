import QtQuick
import QtQuick.Controls
import "."

// Pick a person (slqs only): mode "dm" starts/opens a 1:1 with anyone in the
// workspace (even someone you've never messaged); mode "invite" adds them to the
// current channel. Rows come from Backend.searchUsers — the same in-memory user
// list the @-mention autocomplete uses, so there's no daemon round-trip.
Item {
    id: pp
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 100 } }

    property bool open: false
    property string mode: "dm"    // "dm" | "invite"
    property var rows: []
    property int sel: 0

    function showDM()     { mode = "dm";     _show() }
    function showInvite() { mode = "invite"; _show() }
    function _show() { search.text = ""; sel = 0; open = true; rebuild(); Qt.callLater(() => search.forceActiveFocus()) }
    function hide() { open = false }

    function rebuild() {
        rows = Backend.searchUsers(search.text.trim(), 50)
        sel = 0
        list.positionViewAtBeginning()
    }
    function move(d) { if (rows.length) sel = Math.max(0, Math.min(rows.length - 1, sel + d)); list.positionViewAtIndex(sel, ListView.Contain) }
    function accept() {
        const r = rows[sel]
        if (!r) return
        hide()
        if (mode === "invite") Backend.inviteToChannel(r.id)
        else Backend.openDM(r.id)
    }

    MouseArea { anchors.fill: parent; onClicked: pp.hide() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.45 }

    Rectangle {
        width: Math.round(Math.min(560, parent.width - 80))
        height: header.height + list.height
        x: Math.round((parent.width - width) / 2)
        y: Math.round(parent.height * 0.16)
        radius: Theme.radius
        color: Theme.bg_alt
        border.color: Theme.hairline; border.width: 1
        MouseArea { anchors.fill: parent }

        Column {
            anchors.fill: parent
            Item {
                id: header
                width: parent.width; height: 52
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
                Row {
                    anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 10
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter; text: "@"
                           color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 19 }
                    TextInput { renderType: TextInput.QtRendering;
                        id: search
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 36; color: Theme.fg; clip: true
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 17
                        onTextChanged: pp.rebuild()
                        Keys.onDownPressed: pp.move(1)
                        Keys.onUpPressed: pp.move(-1)
                        Keys.onReturnPressed: pp.accept()
                        Keys.onEscapePressed: pp.hide()
                        Keys.onPressed: e => {
                            if (e.modifiers & Qt.ControlModifier) {
                                if (e.key === Qt.Key_J) { pp.move(1); e.accepted = true }
                                else if (e.key === Qt.Key_K) { pp.move(-1); e.accepted = true }
                            }
                        }
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; visible: !search.text
                               text: pp.mode === "invite" ? "Invite someone to this channel…" : "Message someone…"
                               color: Theme.fg_muted; font: search.font }
                    }
                }
            }
            ListView {
                id: list
                width: parent.width
                height: Math.round(Math.min(440, contentHeight))
                clip: true
                model: pp.rows
                currentIndex: pp.sel
                highlightFollowsCurrentItem: false
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 4000; reuseItems: true
                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    width: list.width; height: 38
                    Rectangle {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                        anchors.topMargin: 1; anchors.bottomMargin: 1; radius: 8
                        color: index === pp.sel ? Theme.selection : hov.hovered ? Theme.hover : "transparent"
                    }
                    Rectangle { anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                        width: 3; height: 20; radius: 2; color: Theme.cursor; visible: index === pp.sel }
                    Row {
                        anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 14; spacing: 9
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
                               text: "@"; color: Theme.fg_muted
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 15 }
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
                               text: row.modelData.name; color: Theme.fg
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 15 }
                    }
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                           anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
                           text: pp.mode === "invite" ? "invite" : "message"
                           color: Theme.green
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12; font.weight: 600 }
                    HoverHandler { id: hov }
                    TapHandler { onTapped: { pp.sel = row.index; pp.accept() } }
                }
            }
        }
    }
}
