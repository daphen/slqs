import QtQuick

// Centered modal shell for the family's ? sheets, confirmations, and the
// changelog. Owns the scrim, panel, scroll, keys, and height math in one place
// so every modal is scrollable by default and the shells stop drifting.
//
// Three slots:
//   header — fixed row(s) at the top (title, search pill). Give it an explicit
//            height; it must not anchor to the panel's height (childrenRect
//            drives the layout). Optional.
//   default children — the scrollable body. Put a single Column/Row with
//            width: parent.width; it flows inside the built-in Flickable.
//   footer — fixed row at the bottom (hint line), same height rule. Optional.
//
// Keys (grabs focus on show, D1=B): esc/q close, j/k scroll, ⌃d/⌃u half-page,
// ↵ emits accepted(). Content gets keyPressed(event) FIRST — accept the event
// to override a default (that is how the ? sheets keep `/`-to-search typing).
// closed() fires on close so the host can reclaim key focus.
Item {
    id: modal
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
    z: 104

    property bool open: false
    property alias header: headerBox.data
    property alias footer: footerBox.data
    default property alias content: bodyCol.data
    property real panelWidth: 460
    property real maxHeightFrac: 0.7
    // Panel fill. Defaults to bg_alt (dialogs); pickers override to Theme.bg so
    // Theme.selection row highlights read (selection ≈ bg_alt in light mode).
    property color panelColor: Theme.bg_alt
    // Opt-in full-bleed bottom "chin" bar behind the footer content (picker hint
    // bars, à la the quickshell pickers). Off by default so dialogs/sheets keep
    // their centered hint row with normal padding.
    property bool chinBar: false
    signal accepted()
    signal closed()
    signal keyPressed(var event)

    function show() { open = true; Qt.callLater(() => { flick.contentY = 0; keyScope.forceActiveFocus() }) }
    function close() { if (open) { open = false; modal.closed() } }
    function scrollBy(dy) {
        flick.contentY = Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + dy))
    }
    function scrollPage(dir) { scrollBy(dir * flick.height * 0.85) }

    readonly property real padV: 24
    readonly property real padH: 24
    readonly property real headerH: headerBox.childrenRect.height
    readonly property real footerH: footerBox.childrenRect.height
    readonly property real gapT: headerH > 0 ? 16 : 0
    // Breathing room below the last row, baked into the scroll content height so
    // it shows only when the list fits or is scrolled to the end — never as a
    // strip over a mid-scroll cut (the scroll area itself reaches the panel edge).
    readonly property real contentPad: padV
    // fixed chrome below the scroll area: footer (+ gap + padding), or none.
    readonly property real belowFlick: footerH > 0 ? (chinBar ? footerH : 16 + footerH + padV) : 0

    MouseArea { anchors.fill: parent; onClicked: modal.close() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.5 }

    FocusScope {
        id: keyScope
        anchors.fill: parent
        Keys.onPressed: e => {
            modal.keyPressed(e)
            if (e.accepted) return
            if (e.key === Qt.Key_Escape || e.key === Qt.Key_Q) { modal.close(); e.accepted = true }
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { modal.accepted(); e.accepted = true }
            else if ((e.modifiers & Qt.ControlModifier) && (e.key === Qt.Key_D || e.key === Qt.Key_U)) {
                modal.scrollPage(e.key === Qt.Key_D ? 1 : -1); e.accepted = true
            }
            else if (e.key === Qt.Key_J) { modal.scrollBy(48); e.accepted = true }
            else if (e.key === Qt.Key_K) { modal.scrollBy(-48); e.accepted = true }
        }

        Rectangle {
            id: panel
            anchors.centerIn: parent
            width: Math.round(modal.panelWidth)
            height: Math.round(Math.min(modal.height * modal.maxHeightFrac,
                     modal.padV + modal.headerH + modal.gapT
                     + bodyCol.implicitHeight + modal.contentPad + modal.belowFlick))
            Behavior on height {
                NumberAnimation { duration: 200; easing.type: Easing.BezierSpline
                                  easing.bezierCurve: [0.165, 0.84, 0.44, 1.0, 1.0, 1.0] }
            }
            radius: Theme.radius
            color: modal.panelColor
            border.color: Theme.hairline; border.width: 1
            clip: true
            MouseArea { anchors.fill: parent }   // swallow clicks over the panel

            Item {
                id: headerBox
                anchors { top: parent.top; left: parent.left; right: parent.right }
                anchors.topMargin: modal.padV; anchors.leftMargin: modal.padH; anchors.rightMargin: modal.padH
                height: childrenRect.height
            }

            Flickable {
                id: flick
                anchors { left: parent.left; right: parent.right }
                anchors.leftMargin: modal.padH; anchors.rightMargin: modal.padH
                anchors.top: headerBox.bottom; anchors.topMargin: modal.gapT
                // reaches the panel edge (footerless) or the footer — content is
                // clipped straight at that edge like overflow:hidden, no strip.
                anchors.bottom: footerBox.top; anchors.bottomMargin: modal.footerH > 0 ? (modal.chinBar ? 0 : 16) : 0
                clip: true
                contentWidth: width
                contentHeight: bodyCol.implicitHeight + modal.contentPad
                flickableDirection: Flickable.VerticalFlick
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                Column { id: bodyCol; width: flick.width }
            }

            // Opt-in chin bar: full-bleed surface flush under the scroll area,
            // spanning exactly the footer content, with a top hairline and rounded
            // bottom corners matching the panel.
            Rectangle {
                id: chin
                visible: modal.chinBar && modal.footerH > 0
                anchors.left: panel.left; anchors.right: panel.right
                anchors.leftMargin: 1; anchors.rightMargin: 1
                anchors.bottom: panel.bottom; anchors.bottomMargin: 1
                anchors.top: footerBox.top
                color: Theme.surface0
                bottomLeftRadius: panel.radius - 1; bottomRightRadius: panel.radius - 1
                Rectangle { anchors { top: parent.top; left: parent.left; right: parent.right }
                            height: 1; color: Theme.hairline }
            }

            Item {
                id: footerBox
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                anchors.bottomMargin: modal.footerH > 0 ? (modal.chinBar ? 0 : modal.padV) : 0
                anchors.leftMargin: modal.chinBar ? 0 : modal.padH
                anchors.rightMargin: modal.chinBar ? 0 : modal.padH
                height: childrenRect.height
            }
        }
    }
}
