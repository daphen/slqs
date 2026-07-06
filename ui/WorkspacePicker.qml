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
        // positionViewAtBeginning clamps to the first item, ignoring
        // topMargin — snap contentY so the margin under the hairline shows.
        if (list) Qt.callLater(() => list.contentY = -list.topMargin)
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

    readonly property string sans: "sans-serif"
    readonly property color panelBorder:
        Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)

    Rectangle {
        width: Math.round(Math.min(480, parent.width - 80))
        height: header.height + list.height
        x: Math.round((parent.width - width) / 2)
        y: Math.round(parent.height * 0.16)
        radius: 14
        color: Theme.bg
        border.color: wp.panelBorder; border.width: 1
        clip: true
        MouseArea { anchors.fill: parent }

        Column {
            anchors.fill: parent
            Item {
                id: header
                width: parent.width; height: 52
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
                Row {
                    anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 10
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter; text: "⇄"
                           color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17 }
                    TextInput { renderType: TextInput.QtRendering;
                        id: search
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 36; color: Theme.fg; clip: true
                        font.family: wp.sans; font.pixelSize: 17
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
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; visible: !search.text; text: "Switch workspace…"
                               color: Theme.fg_muted; font: search.font }
                    }
                }
            }
            ListView {
                id: list
                width: parent.width
                height: Math.round(Math.min(440, contentHeight + 20))
                topMargin: 10
                bottomMargin: 10
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
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        anchors.topMargin: 1; anchors.bottomMargin: 1; radius: 8
                        color: index === wp.sel ? Theme.selection : hov.hovered ? Theme.hover : "transparent"
                    }
                    // Same accent-dot marker the worktree picker uses for the
                    // active entry — right-aligned here so the avatar chips
                    // stay on one column.
                    Rectangle {
                        visible: row.active
                        width: 6; height: 6; radius: 3
                        color: Theme.cursor
                        anchors.right: parent.right; anchors.rightMargin: 22
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Row {
                        anchors.fill: parent; anchors.leftMargin: 22; anchors.rightMargin: 22; spacing: 11
                        ClippingRectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 28; height: 28; radius: 8; color: Theme.hover
                            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.centerIn: parent
                                   visible: wsIcon.status !== Image.Ready
                                   readonly property bool dm: row.modelData.id === "@me"
                                   text: dm ? "" : (row.modelData.name || "?").slice(0, 2).toUpperCase()   // nf-fa-comments for DMs
                                   color: dm ? Theme.fg : Theme.fg_muted
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                                   font.pixelSize: dm ? 15 : 12; font.weight: 600 }
                            Image { id: wsIcon; anchors.fill: parent; source: row.modelData.icon || ""
                                    visible: status === Image.Ready; asynchronous: true; cache: true
                                    fillMode: Image.PreserveAspectCrop; sourceSize.width: 56; sourceSize.height: 56 }
                        }
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
                               text: (row.modelData.id === "@me") ? "Direct Messages" : row.modelData.name; color: Theme.fg
                               font.family: wp.sans
                               font.pixelSize: 14; font.weight: row.active ? 600 : 500 }
                    }
                    HoverHandler { id: hov }
                    TapHandler { onTapped: { wp.sel = row.index; wp.accept() } }
                }
            }
        }
    }
}
