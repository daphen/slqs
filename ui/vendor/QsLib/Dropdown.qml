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
    z: 200

    property bool open: false
    property var model: []             // [{ id, label, badge }]
    property var currentId
    property Item anchorItem: null     // panel drops below this
    property real panelWidth: anchorItem ? anchorItem.width : 220
    property int rowHeight: 40
    property int maxVisible: 8
    // Opt-in keyboard nav. Off by default so the dropdown never steals focus
    // from a host's global key router (which would strand its binds after a
    // close). A modal caller that owns focus can turn this on.
    property bool grabsKeys: false
    signal activated(var id)

    property int sel: 0

    function show() {
        const i = (model || []).findIndex(m => m.id === currentId)
        sel = Math.max(0, i)
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

    readonly property point anchorPos:
        anchorItem ? dd.mapFromItem(anchorItem, 0, anchorItem.height) : Qt.point(0, 0)
    readonly property color panelBorder:
        Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)

    Rectangle {
        id: panel
        x: Math.round(dd.anchorPos.x)
        y: Math.round(dd.anchorPos.y + 6)
        width: Math.round(dd.panelWidth)
        height: list.height
        radius: 16
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
            height: Math.round(Math.min(dd.maxVisible * dd.rowHeight, contentHeight) + 12)
            topMargin: 6; bottomMargin: 6
            clip: true
            model: dd.model
            currentIndex: dd.sel
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            reuseItems: true
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool isCurrent: row.modelData.id === dd.currentId
                readonly property int badge: row.modelData.badge || 0
                width: list.width; height: dd.rowHeight

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 8; anchors.rightMargin: 8
                    anchors.topMargin: 1; anchors.bottomMargin: 1; radius: 10
                    color: row.index === dd.sel ? Theme.selection
                         : hov.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: row.index === dd.sel ? Theme.hairline : "transparent"
                }
                // left accent bar marks the active account (mlqs folder-row idiom)
                Rectangle {
                    visible: row.isCurrent
                    anchors.left: parent.left; anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3; height: 16; radius: 2; color: Theme.cursor
                }
                Text {
                    anchors.left: parent.left; anchors.leftMargin: 28
                    anchors.right: badgePill.visible ? badgePill.left : parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.label || ""
                    color: Theme.fg
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 13; font.weight: row.isCurrent ? 500 : 400
                    elide: Text.ElideRight
                }
                Rectangle {
                    id: badgePill
                    visible: row.badge > 0
                    anchors.right: parent.right; anchors.rightMargin: 16
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
                HoverHandler { id: hov }
                TapHandler { onTapped: { dd.sel = row.index; dd.accept() } }
            }
        }
    }
}
