import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import "."
import QsLib

// Ctrl+K command palette: centered overlay. Empty query shows recent threads
// and DMs at the top; typing fuzzy-searches every channel/DM. Enter jumps.
Item {
    id: palette
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 110 } }

    property bool open: false
    signal channelSelected()   // a channel (not a thread) was chosen → focus chat
    function show() { search.text = ""; open = true; sel = 0; rebuild(); Qt.callLater(() => search.forceActiveFocus()) }
    function hide() { open = false }

    property var rows: []        // [{kind:'divider',label} | {kind,name,topic,sub,ts,channel}]
    property int sel: 0

    function _selectableIndices() {
        const out = []
        for (let i = 0; i < rows.length; i++) if (rows[i].kind !== "divider") out.push(i)
        return out
    }
    function move(d) {
        const sels = _selectableIndices()
        if (sels.length === 0) return
        let pos = sels.indexOf(sel)
        pos = Math.max(0, Math.min(sels.length - 1, pos + d))
        sel = sels[pos]
        list.positionViewAtIndex(sel, ListView.Contain)
    }
    function accept() {
        const r = rows[sel]
        if (!r || r.kind === "divider") return
        hide()
        // Either way the chat (not the sidebar) becomes the underlying panel,
        // so closing a thread lands back on the conversation.
        palette.channelSelected()
        if (r.kind === "thread") Backend.openThreadFromSub(r.thread)
        else Backend.selectChannel(r.id, r.name, r.topic)
    }

    function rebuild() {
        const q = search.text.trim().toLowerCase()
        const out = []
        const chans = Backend.channels
        if (q === "") {
            const st = Backend.currentSubThreads
            if (st.length) {
                out.push({ kind: "divider", label: "Threads" })
                for (let i = 0; i < st.length; i++)
                    out.push({ kind: "thread",
                               name: st[i].preview || st[i].title,
                               sub: "#" + (st[i].channelName || "") + " · " + st[i].title,
                               unread: st[i].unread || 0, thread: st[i] })
            }
            const dms = [], chs = []
            for (let i = 0; i < chans.count; i++) {
                const c = chans.get(i)
                const item = { kind: c.kind, id: c.id, name: c.name, topic: c.topic, sub: c.kind === "dm" ? "direct message" : (c.topic || "channel") }
                if (c.kind === "dm") dms.push(item); else chs.push(item)
            }
            if (dms.length) { out.push({ kind: "divider", label: "Direct messages" }); dms.forEach(x => out.push(x)) }
            if (chs.length) { out.push({ kind: "divider", label: "Channels" }); chs.forEach(x => out.push(x)) }
        } else {
            const scored = []
            for (let i = 0; i < chans.count; i++) {
                const c = chans.get(i)
                const n = c.name.toLowerCase()
                const idx = n.indexOf(q)
                if (idx < 0) continue
                scored.push({ item: { kind: c.kind, id: c.id, name: c.name, topic: c.topic,
                                      sub: c.kind === "dm" ? "direct message" : (c.topic || "channel") },
                              score: (idx === 0 ? 0 : 100) + idx })
            }
            scored.sort((a, b) => a.score - b.score)
            scored.forEach(s => out.push(s.item))
        }
        rows = out
        const sels = _selectableIndices()
        sel = sels.length ? sels[0] : 0
    }

    // scrim
    MouseArea {
        anchors.fill: parent
        onClicked: palette.hide()
    }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.45 }

    // Plain Rectangle, NOT ClippingRectangle: the latter renders children into
    // an offscreen texture at 1x DPR, which blurs text on a fractional-scale
    // monitor. The ListView clips itself, so we don't need the rounded clip.
    Rectangle {
        // Integer x/y: QtRendering text on a half-pixel baseline (from
        // centering / fractional y) renders soft. Snap to whole pixels.
        width: Math.round(Math.min(620, parent.width - 80))
        height: header.height + list.height   // exact fit — no bottom gap
        x: Math.round((parent.width - width) / 2)
        y: Math.round(parent.height * 0.16)
        radius: 24
        color: Theme.bg
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10); border.width: 1

        MouseArea { anchors.fill: parent }   // swallow clicks (don't close)

        Column {
            anchors.fill: parent

            // search box
            Item {
                id: header
                width: parent.width; height: 66
                Rectangle {
                    id: searchField
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    anchors.topMargin: 14; anchors.bottomMargin: 6
                    radius: 15
                    color: Theme.surface1
                    border.width: 1
                    border.color: Theme.hairline
                }
                Row {
                    anchors.fill: searchField; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "⌕"
                           color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 19 }
                    TextInput { 
                        id: search
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 36; color: Theme.fg; clip: true
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17
                        onTextChanged: palette.rebuild()
                        Keys.onDownPressed: palette.move(1)
                        Keys.onUpPressed: palette.move(-1)
                        Keys.onReturnPressed: palette.accept()
                        Keys.onEscapePressed: palette.hide()
                        Keys.onPressed: e => {
                            if (e.modifiers & Qt.ControlModifier) {
                                if (e.key === Qt.Key_J) { palette.move(1); e.accepted = true }
                                else if (e.key === Qt.Key_K) { palette.move(-1); e.accepted = true }
                            }
                        }
                        Text { visible: !search.text; text: "Jump to a channel or DM…"
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
                model: palette.rows
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                // Drive selection via the ListView's own currentIndex — reading
                // palette.sel directly from a var-array delegate scope didn't
                // re-evaluate reliably; isCurrentItem does.
                currentIndex: palette.sel
                highlightFollowsCurrentItem: false
                delegate: Item {
                    id: del
                    required property var modelData
                    required property int index
                    width: list.width
                    readonly property bool isDivider: modelData.kind === "divider"
                    height: isDivider ? 34 : 52

                    // divider
                    Text { 
                        visible: del.isDivider
                        x: 16; y: 12
                        text: del.isDivider ? modelData.label.toUpperCase() : ""
                        color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 12; font.weight: 500
                    }

                    // selectable row — inset + rounded so the highlight never
                    // touches the box's rounded corners or border
                    Rectangle {
                        visible: !del.isDivider
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        anchors.topMargin: 1; anchors.bottomMargin: 1; radius: 13
                        color: del.ListView.isCurrentItem ? Theme.selection
                             : hov.hovered ? Theme.hover : "transparent"
                        border.width: 1
                        border.color: del.ListView.isCurrentItem ? Theme.hairline : "transparent"
                        Row {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 12; spacing: 9
                            Text { 
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.kind === "dm" ? "●" : (modelData.kind === "thread" ? "" : "#")
                                color: modelData.kind === "dm" ? Theme.green : Theme.fg_muted
                                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: modelData.kind === "dm" ? 10 : 14
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 40 - (badge.visible ? 32 : 0); spacing: 3
                                Text { text: modelData.name || ""; color: Theme.fg
                                       elide: Text.ElideRight; width: parent.width; maximumLineCount: 1; wrapMode: Text.NoWrap
                                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15; font.weight: 500 }
                                Text { visible: !!modelData.sub; text: modelData.sub || ""
                                       color: Theme.fg_muted; elide: Text.ElideRight; width: parent.width; maximumLineCount: 1; wrapMode: Text.NoWrap
                                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12 }
                            }
                        }
                        Rectangle {   // unread badge (e.g. thread replies)
                            id: badge
                            visible: (modelData.unread || 0) > 0
                            anchors.right: parent.right; anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            height: 18; width: Math.max(18, bt.implicitWidth + 10); radius: 9
                            color: Theme.cursor
                            Text { id: bt; anchors.centerIn: parent
                                   text: modelData.unread || ""; color: Theme.ink
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                                   font.pixelSize: 12; font.weight: 500 }
                        }
                        HoverHandler { id: hov }
                        TapHandler { onTapped: { palette.sel = del.index; palette.accept() } }
                    }
                }
                ScrollBar.vertical: ScrollBar { width: 6; policy: ScrollBar.AsNeeded }
            }
        }
    }
}
