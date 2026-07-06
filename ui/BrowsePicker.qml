import QtQuick
import "."

// Browse & join public channels (`b`). Requests the full list from slqs, filter
// by typing; Enter joins a channel (or just opens it if already a member).
Item {
    id: bp
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 100 } }

    property bool open: false
    property var rows: []
    property int sel: 0

    function show() { search.text = ""; rows = []; sel = 0; open = true; Backend.requestBrowse(); Qt.callLater(() => search.forceActiveFocus()) }
    function hide() { open = false }
    function rebuild() {
        const q = search.text.trim().toLowerCase()
        const all = Backend.browseResults || []
        const out = []
        for (let i = 0; i < all.length; i++)
            if (!q || all[i].name.toLowerCase().indexOf(q) >= 0) out.push(all[i])
        rows = out; sel = 0; list.positionViewAtBeginning()
    }
    function move(d) { if (rows.length) sel = Math.max(0, Math.min(rows.length - 1, sel + d)); list.positionViewAtIndex(sel, ListView.Contain) }
    function accept() {
        const r = rows[sel]
        if (!r) return
        hide()
        if (r.member) Backend.selectChannel(r.id, r.name, "")
        else Backend.joinChannel(r.id, r.name)
    }
    Connections { target: Backend; function onBrowseLoaded() { bp.rebuild() } }

    MouseArea { anchors.fill: parent; onClicked: bp.hide() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.45 }

    Rectangle {
        width: Math.round(Math.min(560, parent.width - 80))
        height: header.height + list.height
        x: Math.round((parent.width - width) / 2)
        y: Math.round(parent.height * 0.16)
        radius: 24
        color: Theme.bg
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10); border.width: 1
        MouseArea { anchors.fill: parent }

        Column {
            anchors.fill: parent
            Item {
                id: header
                width: parent.width; height: 66
                Rectangle {
                    id: searchField
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    anchors.topMargin: 14; anchors.bottomMargin: 6
                    radius: 15
                    color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.07)
                }
                Row {
                    anchors.fill: searchField; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter; text: "#"
                           color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 19 }
                    TextInput { renderType: TextInput.QtRendering;
                        id: search
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 36; color: Theme.fg; clip: true
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17
                        onTextChanged: bp.rebuild()
                        Keys.onDownPressed: bp.move(1)
                        Keys.onUpPressed: bp.move(-1)
                        Keys.onReturnPressed: bp.accept()
                        Keys.onEscapePressed: bp.hide()
                        Keys.onPressed: e => {
                            if (e.modifiers & Qt.ControlModifier) {
                                if (e.key === Qt.Key_J) { bp.move(1); e.accepted = true }
                                else if (e.key === Qt.Key_K) { bp.move(-1); e.accepted = true }
                            }
                        }
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; visible: !search.text; text: "Browse channels to join…"
                               color: Theme.fg_muted; font: search.font }
                    }
                }
            }
            ListView {
                id: list
                width: parent.width
                height: Math.round(Math.min(440, contentHeight + 18))
                topMargin: 8
                bottomMargin: 10
                clip: true
                model: bp.rows
                currentIndex: bp.sel
                highlightFollowsCurrentItem: false
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 4000; reuseItems: true
                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    width: list.width; height: 38
                    Rectangle {   // inset + rounded highlight, clear of the box corners/border
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        anchors.topMargin: 1; anchors.bottomMargin: 1; radius: 13
                        color: index === bp.sel ? Theme.selection : hov.hovered ? Theme.hover : "transparent"
                        border.width: 1
                        border.color: index === bp.sel ? Theme.hairline : "transparent"
                    }
                    Row {
                        anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 14; spacing: 9
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
                               text: "#"; color: Theme.fg_muted
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15 }
                        Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; anchors.verticalCenter: parent.verticalCenter
                               text: row.modelData.name; color: Theme.fg
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15 }
                    }
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                           anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
                           text: row.modelData.member ? "joined" : "join"
                           color: row.modelData.member ? Theme.fg_muted : Theme.green
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12; font.weight: 600 }
                    HoverHandler { id: hov }
                    TapHandler { onTapped: { bp.sel = row.index; bp.accept() } }
                }
            }
        }
    }
}
