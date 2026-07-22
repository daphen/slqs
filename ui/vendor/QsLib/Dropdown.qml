import QtQuick

// Inline dropdown / select — the family picker's panel + row style, minus the
// search field, dropped below an anchor Item. Generic: feed `model` (array of
// { id, label, badge }), bind `currentId`, handle `activated(id)`. The caller
// renders its own trigger and calls toggle()/show()/hide().
//
// Fills its parent and floats a panel below `anchorItem`; place it in a
// non-clipping container tall enough for the panel to drop into. Motion tokens
// drive the open/close so it matches the rest of the family.
Item {
    id: dd
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
    z: 999

    property bool open: false
    property var model: []             // [{ id, label, badge }]
    property var currentId
    property Item anchorItem: null     // panel drops below this
    property real gap: 6               // space between the anchor's bottom and the panel
    property real panelWidth: anchorItem ? anchorItem.width : 220
    property int rowHeight: 44   // matches the family picker row
    property int maxVisible: 8
    // Opt-in keyboard nav. Off by default so the dropdown never steals focus
    // from a host's global key router (which would strand its binds after a
    // close). A modal caller that owns focus can turn this on.
    property bool grabsKeys: false
    signal activated(var id)

    property int sel: 0

    // Panel position, computed at open time. mapFromItem in a plain binding
    // doesn't track the anchor's absolute position (only its size), so it goes
    // stale when the layout around the anchor shifts — recompute on show().
    property real panelX: 0
    property real panelY: 0
    function reposition() {
        if (!anchorItem) return
        const p = dd.mapFromItem(anchorItem, 0, anchorItem.height)
        panelX = p.x
        panelY = p.y + gap
    }
    function show() {
        const i = (model || []).findIndex(m => m.id === currentId)
        sel = Math.max(0, i)
        reposition()
        open = true
        if (grabsKeys) Qt.callLater(() => keyCatch.forceActiveFocus())
    }
    function hide() { open = false }
    function toggle() { if (open) hide(); else show() }
    function move(d) {
        const n = (model || []).length
        if (n) sel = Math.max(0, Math.min(n - 1, sel + d))
    }
    function accept() {
        const r = (model || [])[sel]
        if (r) { hide(); dd.activated(r.id) }
    }

    // Transparent outside-click catcher — a dropdown doesn't dim the screen the
    // way the full pickers do; it just dismisses on a click elsewhere.
    MouseArea { anchors.fill: parent; onClicked: dd.hide() }

    Item {
        id: keyCatch
        focus: dd.open && dd.grabsKeys
        Keys.onUpPressed: dd.move(-1)
        Keys.onDownPressed: dd.move(1)
        Keys.onReturnPressed: dd.accept()
        Keys.onEscapePressed: dd.hide()
        Keys.onPressed: e => {
            if (e.modifiers & Qt.ControlModifier) {
                if (e.key === Qt.Key_J) { dd.move(1); e.accepted = true }
                else if (e.key === Qt.Key_K) { dd.move(-1); e.accepted = true }
            }
        }
    }

    readonly property color panelBorder:
        Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)

    Rectangle {
        id: panel
        x: Math.round(dd.panelX)
        y: Math.round(dd.panelY)
        width: Math.round(dd.panelWidth)
        height: list.height
        radius: 18
        color: Theme.bg
        border.color: dd.panelBorder; border.width: 1
        clip: true
        // expand from the top edge as it fades in
        transformOrigin: Item.Top
        scale: dd.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeOut } }
        MouseArea { anchors.fill: parent }   // swallow clicks over the panel

        ListView {
            id: list
            width: parent.width
            // picker: topMargin/bottomMargin 10 under the hairline
            height: Math.round(Math.min(dd.maxVisible * dd.rowHeight, contentHeight) + 20)
            topMargin: 10; bottomMargin: 10
            clip: true
            model: dd.model
            currentIndex: dd.sel
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            reuseItems: true
            // Row idioms lifted from WorkspacePicker: inset rounded highlight,
            // initials chip, right-aligned accent dot for the active entry.
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool isCurrent: row.modelData.id === dd.currentId
                readonly property int badge: row.modelData.badge || 0
                width: list.width; height: dd.rowHeight

                // inset highlight — never touches the panel's rounded corners
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    anchors.topMargin: 1; anchors.bottomMargin: 1; radius: 13
                    color: row.index === dd.sel ? Theme.selection
                         : hov.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: row.index === dd.sel ? Theme.hairline : "transparent"
                }
                // right-aligned accent dot for the active entry (picker idiom)
                Rectangle {
                    visible: row.isCurrent && row.badge === 0
                    width: 6; height: 6; radius: 3; color: Theme.cursor
                    anchors.right: parent.right; anchors.rightMargin: 22
                    anchors.verticalCenter: parent.verticalCenter
                }
                // unread on the other entries, same corner slot as the dot
                Rectangle {
                    id: badgePill
                    visible: row.badge > 0
                    anchors.right: parent.right; anchors.rightMargin: 18
                    anchors.verticalCenter: parent.verticalCenter
                    height: 16; width: Math.max(16, bt.implicitWidth + 8); radius: 8
                    color: Theme.cursor
                    Text {
                        id: bt; anchors.centerIn: parent
                        text: row.badge > 99 ? "99+" : row.badge
                        color: Theme.ink
                        font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: 600
                        font.features: ({ "tnum": 1 })
                    }
                }
                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 22
                    anchors.rightMargin: badgePill.visible ? 44 : 28
                    spacing: 11
                    // initials chip (picker's non-icon workspace look)
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 28; height: 28; radius: 8; color: Theme.hover
                        Text {
                            anchors.centerIn: parent
                            text: (row.modelData.label || "?").slice(0, 2).toUpperCase()
                            color: Theme.fg_muted
                            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                            font.pixelSize: 12; font.weight: 500
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, dd.panelWidth - 100)
                        text: row.modelData.label || ""
                        color: Theme.fg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 14; font.weight: row.isCurrent ? 500 : 400
                        elide: Text.ElideRight
                    }
                }
                HoverHandler { id: hov }
                TapHandler { onTapped: { dd.sel = row.index; dd.accept() } }
            }
        }
    }
}
