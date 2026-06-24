import QtQuick
import "."

// Emoji picker overlay. Opened to react to a message (`r`). Type to filter;
// j/k or ↑/↓ to move; Enter/Tab/click to pick. Custom (workspace) emoji render
// as images and sort first; standard emoji show their glyph.
Item {
    id: picker
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 100 } }

    property bool open: false
    property int sel: 0
    property var rows: []
    signal picked(string name)

    function show() { search.text = ""; open = true; rebuild(); if (target) Backend.fetchReactors(target); Qt.callLater(() => search.forceActiveFocus()) }
    function hide() { open = false }
    // Re-render when fetched reactor names arrive for the message we're showing.
    Connections {
        target: Backend
        function onReactorsReady(ts) { if (picker.open && picker.target && picker.target.ts === ts) picker.rebuild() }
    }
    function rebuild() {
        const q = search.text.trim().toLowerCase()
        const emojis = Backend.searchEmoji(q, 120)
        // With no query, list the message's existing reactions first (who reacted
        // with what); selecting one toggles it. Typing filters to the emoji grid.
        if (q.length === 0 && target && target.reactionsJson) {
            let reacts = []
            try {
                const rx = JSON.parse(target.reactionsJson)
                for (let i = 0; i < rx.length; i++) {
                    const r = rx[i]
                    // Custom emoji icon: dsqrd carries a CDN `img`; slqs uses a
                    // :name: that maps to a cached file. Else it's a unicode glyph.
                    const colonName = /^:[a-z0-9_+'\-]+:$/.test(r.e || "") ? r.e.slice(1, -1) : ""
                    const imgPath = r.img ? r.img : (colonName ? Backend.emojiPath(colonName) : "")
                    reacts.push({ kind: "reaction", name: r.name,
                        custom: imgPath !== "", path: imgPath,
                        glyph: imgPath ? "" : (r.e || ""),
                        count: r.n || 0, mine: !!r.mine,
                        users: (r.users && r.users.length) ? r.users : Backend.reactorsFor(target.ts, r.name) })
                }
            } catch (e) {}
            rows = reacts.concat(emojis)
        } else {
            rows = emojis
        }
        sel = 0; list.positionViewAtBeginning()
    }
    function move(d) { if (rows.length) sel = Math.max(0, Math.min(rows.length - 1, sel + d)); list.positionViewAtIndex(sel, ListView.Contain) }
    function accept() { const r = rows[sel]; if (r) { hide(); picker.picked(r.name) } }

    MouseArea { anchors.fill: parent; onClicked: picker.hide() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.45 }

    Rectangle {
        width: Math.round(Math.min(420, parent.width - 80))
        height: header.height + list.height
        x: Math.round((parent.width - width) / 2)
        y: Math.round(parent.height * 0.2)
        radius: Theme.radius
        color: Theme.bg_alt
        border.color: Theme.hairline; border.width: 1
        MouseArea { anchors.fill: parent }

        Column {
            anchors.fill: parent
            Item {
                id: header
                width: parent.width; height: 48
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
                Row {
                    anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 10
                    Text { renderType: Text.QtRendering; anchors.verticalCenter: parent.verticalCenter; text: "☺"
                           color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 18 }
                    TextInput { renderType: TextInput.QtRendering;
                        id: search
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 36; color: Theme.fg; clip: true
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 16
                        onTextChanged: picker.rebuild()
                        Keys.onDownPressed: picker.move(1)
                        Keys.onUpPressed: picker.move(-1)
                        Keys.onReturnPressed: picker.accept()
                        Keys.onEscapePressed: picker.hide()
                        Keys.onPressed: e => {
                            if (e.key === Qt.Key_Tab) { picker.accept(); e.accepted = true }
                            else if (e.modifiers & Qt.ControlModifier) {
                                if (e.key === Qt.Key_J) { picker.move(1); e.accepted = true }
                                else if (e.key === Qt.Key_K) { picker.move(-1); e.accepted = true }
                            }
                        }
                        Text { renderType: Text.QtRendering; visible: !search.text; text: "React with…"
                               color: Theme.fg_muted; font: search.font }
                    }
                }
            }

            ListView {
                id: list
                width: parent.width
                height: Math.round(Math.min(360, contentHeight))
                clip: true
                model: picker.rows
                currentIndex: picker.sel
                highlightFollowsCurrentItem: false
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 4000; reuseItems: true
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool isReaction: row.modelData.kind === "reaction"
                    width: list.width; height: 36
                    color: "transparent"
                    // inset, rounded highlight (matches the other pickers — never touches the box corners)
                    Rectangle {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                        anchors.topMargin: 1; anchors.bottomMargin: 1; radius: 8
                        color: index === picker.sel ? Theme.selection : hov.hovered ? Theme.hover : "transparent"
                    }
                    Rectangle { anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                        width: 3; height: 22; radius: 2; color: Theme.cursor; visible: index === picker.sel }
                    Row {
                        anchors.left: parent.left; anchors.right: parent.right
                        anchors.leftMargin: 18; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        Item {
                            width: 22; height: 22; anchors.verticalCenter: parent.verticalCenter
                            Image { anchors.fill: parent; visible: row.modelData.custom; source: row.modelData.path || ""
                                    fillMode: Image.PreserveAspectFit; sourceSize.width: 44; sourceSize.height: 44 }
                            Text { renderType: Text.QtRendering; anchors.centerIn: parent; visible: !row.modelData.custom
                                   text: row.modelData.glyph || ""; font.pixelSize: 19 }
                        }
                        // reaction row: count + who reacted; the mine ones are bold/accent
                        Text { renderType: Text.QtRendering; visible: row.isReaction; anchors.verticalCenter: parent.verticalCenter
                               width: 26; text: row.modelData.count
                               color: row.modelData.mine ? Theme.sky : Theme.fg
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14; font.weight: 700 }
                        Text { renderType: Text.QtRendering; visible: row.isReaction; anchors.verticalCenter: parent.verticalCenter
                               width: row.width - 90; elide: Text.ElideRight
                               text: (row.modelData.users || []).join(", "); color: Theme.fg_muted
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13 }
                        // emoji row: :name:
                        Text { renderType: Text.QtRendering; visible: !row.isReaction; anchors.verticalCenter: parent.verticalCenter
                               text: ":" + row.modelData.name + ":"; color: Theme.fg
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14 }
                    }
                    HoverHandler { id: hov }
                    TapHandler { onTapped: { picker.sel = row.index; picker.accept() } }
                }
            }
        }
    }
}
