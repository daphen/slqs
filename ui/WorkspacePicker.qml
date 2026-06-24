import QtQuick
import Quickshell.Widgets
import "."

// Jump between workspaces/servers (Ctrl+S). Replaces the always-on Discord rail:
// filter by typing, Enter/click switches. Lists Backend.workspaces (DMs + guilds
// for Discord; the team list for Slack).
Item {
    id: wp
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 100 } }

    property bool open: false
    property var rows: []
    property int sel: 0

    function show() { search.text = ""; rebuild(); open = true; Qt.callLater(() => search.forceActiveFocus()) }
    function hide() { open = false }
    function rebuild() {
        const q = search.text.trim().toLowerCase()
        const all = Backend.workspaces || []
        const out = []
        for (let i = 0; i < all.length; i++)
            if (!q || (all[i].name || "").toLowerCase().indexOf(q) >= 0) out.push(all[i])
        rows = out; sel = 0
        if (list) list.positionViewAtBeginning()
    }
    function move(d) { if (rows.length) sel = Math.max(0, Math.min(rows.length - 1, sel + d)); list.positionViewAtIndex(sel, ListView.Contain) }
    function accept() {
        const r = rows[sel]
        if (!r) return
        hide()
        Backend.switchWorkspace(r.id)
    }

    MouseArea { anchors.fill: parent; onClicked: wp.hide() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.45 }

    Rectangle {
        width: Math.round(Math.min(480, parent.width - 80))
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
                    Text { renderType: Text.QtRendering; anchors.verticalCenter: parent.verticalCenter; text: "⇄"
                           color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 17 }
                    TextInput { renderType: TextInput.QtRendering;
                        id: search
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 36; color: Theme.fg; clip: true
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 17
                        onTextChanged: wp.rebuild()
                        Keys.onDownPressed: wp.move(1)
                        Keys.onUpPressed: wp.move(-1)
                        Keys.onReturnPressed: wp.accept()
                        Keys.onEscapePressed: wp.hide()
                        Keys.onPressed: e => {
                            if (e.modifiers & Qt.ControlModifier) {
                                if (e.key === Qt.Key_J) { wp.move(1); e.accepted = true }
                                else if (e.key === Qt.Key_K) { wp.move(-1); e.accepted = true }
                            }
                        }
                        Text { renderType: Text.QtRendering; visible: !search.text; text: "Switch workspace…"
                               color: Theme.fg_muted; font: search.font }
                    }
                }
            }
            ListView {
                id: list
                width: parent.width
                height: Math.round(Math.min(440, contentHeight))
                clip: true
                model: wp.rows
                currentIndex: wp.sel
                highlightFollowsCurrentItem: false
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 4000; reuseItems: true
                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool active: row.modelData.id === Backend.currentWorkspace
                    width: list.width; height: 44
                    // inset, rounded highlight so it never touches the box's
                    // rounded corners or border
                    Rectangle {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                        anchors.topMargin: 1; anchors.bottomMargin: 1; radius: 8
                        color: index === wp.sel ? Theme.selection : hov.hovered ? Theme.hover : "transparent"
                    }
                    Rectangle { anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                        width: 3; height: 24; radius: 2; color: Theme.cursor; visible: index === wp.sel }
                    Row {
                        anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 11
                        ClippingRectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 28; height: 28; radius: 8; color: Theme.hover
                            Text { renderType: Text.QtRendering; anchors.centerIn: parent
                                   visible: wsIcon.status !== Image.Ready
                                   readonly property bool dm: row.modelData.id === "@me"
                                   text: dm ? "" : (row.modelData.name || "?").slice(0, 2).toUpperCase()   // nf-fa-comments for DMs
                                   color: dm ? Theme.fg : Theme.fg_muted
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                                   font.pixelSize: dm ? 15 : 12; font.weight: 700 }
                            Image { id: wsIcon; anchors.fill: parent; source: row.modelData.icon || ""
                                    visible: status === Image.Ready; asynchronous: true; cache: true
                                    fillMode: Image.PreserveAspectCrop; sourceSize.width: 56; sourceSize.height: 56 }
                        }
                        Text { renderType: Text.QtRendering; anchors.verticalCenter: parent.verticalCenter
                               text: (row.modelData.id === "@me") ? "Direct Messages" : row.modelData.name; color: Theme.fg
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                               font.pixelSize: 15; font.weight: row.active ? 700 : 500 }
                    }
                    Text { renderType: Text.QtRendering
                           anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
                           text: row.active ? "current" : ""; color: Theme.fg_muted
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12; font.weight: 700 }
                    HoverHandler { id: hov }
                    TapHandler { onTapped: { wp.sel = row.index; wp.accept() } }
                }
            }
        }
    }
}
