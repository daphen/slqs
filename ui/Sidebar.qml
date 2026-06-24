import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import "."

Rectangle {
    id: sidebar
    color: Theme.bg_alt
    property bool active: true   // is this the focused panel?
    // Active panel gets the border (below); inactive dims slightly.
    opacity: active ? 1.0 : 0.8
    Behavior on opacity { NumberAnimation { duration: 120 } }
    signal searchClosed()
    signal threadsClicked()
    signal workspacePickerRequested()

    // The pinned "Threads" row sits above the channel list as a virtual
    // top item; threadsSelected===true means the cursor is on it.
    property bool threadsSelected: false
    function move(d) {
        if (threadsSelected) {
            if (d > 0) { threadsSelected = false; list.currentIndex = 0 }   // down → first channel
            return
        }
        // Threads is a virtual top item only when the backend supports threads.
        if (Backend.hasThreads && d < 0 && list.currentIndex === 0) { threadsSelected = true; return }
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + d))
    }
    function toTop()    { threadsSelected = Backend.hasThreads; list.currentIndex = 0; list.positionViewAtBeginning() }
    function toBottom() { threadsSelected = false; list.currentIndex = list.count - 1 }
    function openCurrent() {
        if (threadsSelected) { sidebar.threadsClicked(); return }
        const it = Backend.channels.get(list.currentIndex)
        if (it) Backend.selectChannel(it.id, it.name, it.topic)
    }
    function focusSearch() { search.forceActiveFocus() }

    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.hairline }

    // focused-panel accent: a full border around the active panel. Theme.fg is
    // theme-adaptive (light on dark theme, dark on light) — orange didn't read.
    Rectangle {
        anchors.fill: parent; z: 10
        color: "transparent"
        topLeftRadius: 10   // only the window-edge corner; the right edge is internal
        border.width: 2
        // orange while the search field is focused (sidebar insert mode)
        border.color: search.activeFocus ? Theme.cursor : Theme.fg
        visible: sidebar.active
    }

    Column {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 10

        // Workspace switcher. Slack: tabs across the top. Discord (rail hidden):
        // a single current-workspace header that opens the Ctrl+S picker. Hidden
        // entirely when the vertical rail is shown.
        Item {
            readonly property bool railShown: Backend.useRail && !Backend.railHidden
            visible: !railShown
            width: parent.width; height: railShown ? 0 : 34
            // Slack: workspace tabs
            Row {
                visible: !Backend.useRail
                anchors.verticalCenter: parent.verticalCenter; spacing: 4
                Repeater {
                    model: Backend.workspaces
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool active: modelData.id === Backend.currentWorkspace
                        height: 26; radius: 6
                        width: Math.min(tabLbl.implicitWidth + 20, 110)
                        // Snap, don't animate: a color fade on the active tab reads as a
                        // "blink" when switching workspaces (same reason the msg cursor snaps).
                        color: active ? Theme.selection : tabHov.hovered ? Theme.hover : "transparent"
                        Text { id: tabLbl; renderType: Text.QtRendering
                            anchors.centerIn: parent; width: parent.width - 12; elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData.name
                            color: active ? Theme.fg : Theme.fg_muted
                            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                            font.pixelSize: 14; font.weight: active ? 700 : 500
                        }
                        HoverHandler { id: tabHov }
                        TapHandler { onTapped: Backend.switchWorkspace(modelData.id) }
                    }
                }
            }
            // Discord (rail hidden): current workspace; click (or Ctrl+S) to switch
            Rectangle {
                visible: Backend.useRail && Backend.railHidden
                anchors.fill: parent; radius: 6
                color: wsHdrHov.hovered ? Theme.hover : "transparent"
                Row {
                    anchors.left: parent.left; anchors.leftMargin: 4
                    anchors.verticalCenter: parent.verticalCenter; spacing: 6
                    Text { renderType: Text.QtRendering; anchors.verticalCenter: parent.verticalCenter
                        text: Backend.currentWorkspaceName || "Direct Messages"; color: Theme.fg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                        font.pixelSize: 15; font.weight: 700 }
                    Text { renderType: Text.QtRendering; anchors.verticalCenter: parent.verticalCenter
                        text: "⌄"; color: Theme.fg_muted
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13 }
                }
                Text { renderType: Text.QtRendering; anchors.right: parent.right; anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter; text: "⌃S"; color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 11 }
                HoverHandler { id: wsHdrHov }
                TapHandler { onTapped: sidebar.workspacePickerRequested() }
            }
        }

        Rectangle {
            width: parent.width; height: 32; radius: Theme.radiusSm
            color: Theme.bg; border.width: 1
            border.color: search.activeFocus ? Theme.cursor : Theme.hairline
            Row {
                anchors.fill: parent; anchors.leftMargin: 9; spacing: 7
                Text { renderType: Text.QtRendering; anchors.verticalCenter: parent.verticalCenter; text: "⌕"
                       color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 16 }
                TextInput { renderType: TextInput.QtRendering;
                    id: search
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 30; color: Theme.fg; clip: true
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14
                    Keys.onEscapePressed: { text = ""; sidebar.searchClosed() }
                    Text { renderType: Text.QtRendering; visible: !search.text && !search.activeFocus; text: "Jump to…"
                           color: Theme.fg_muted; font: search.font }
                }
            }
        }

        // Pinned "Threads" entry — opens the threads list (Ctrl+K palette).
        // Hidden when the backend has no threads (Discord).
        Rectangle {
            visible: Backend.hasThreads
            width: parent.width; height: Backend.hasThreads ? 30 : 0; clip: true; radius: Theme.radiusSm
            color: (sidebar.threadsSelected && sidebar.active) ? Theme.selection
                 : thHov.hovered ? Theme.hover : "transparent"
            Row {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 7
                Text { renderType: Text.QtRendering; anchors.verticalCenter: parent.verticalCenter
                       text: "↳"; color: Theme.fg_muted
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 15 }
                Text { renderType: Text.QtRendering; anchors.verticalCenter: parent.verticalCenter
                       text: "Threads"; color: Theme.fg
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                       font.pixelSize: 14; font.weight: Backend.threadUnreadTotal > 0 ? 700 : Theme.fontWeight }
            }
            Rectangle {
                visible: Backend.threadUnreadTotal > 0
                anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                height: 17; width: Math.max(17, tb.implicitWidth + 10); radius: 9; color: Theme.cursor
                Text { id: tb; renderType: Text.QtRendering; anchors.centerIn: parent
                       text: Backend.threadUnreadTotal; color: Theme.ink
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                       font.pixelSize: 12; font.weight: 700 }
            }
            HoverHandler { id: thHov }
            TapHandler { onTapped: { sidebar.threadsSelected = true; sidebar.threadsClicked() } }
        }

        ListView {
            id: list
            width: parent.width
            height: parent.height - y
            clip: true
            model: Backend.channels
            currentIndex: 0
            boundsBehavior: Flickable.StopAtBounds
            spacing: 1
            highlightFollowsCurrentItem: false   // wheel scroll must not snap to the cursor
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

            WheelHandler {
                acceptedDevices: PointerDevice.TouchPad | PointerDevice.Mouse
                onWheel: e => {
                    const px = (e.pixelDelta.y !== 0) ? e.pixelDelta.y : e.angleDelta.y / 8
                    const maxY = Math.max(0, list.contentHeight - list.height)
                    list.contentY = Math.max(0, Math.min(maxY, list.contentY - px * 4.5))
                    e.accepted = true
                }
            }

            section.property: "section"
            section.delegate: Text { renderType: Text.QtRendering;
                required property string section
                topPadding: 12; bottomPadding: 4; leftPadding: 6
                text: section.toUpperCase()
                color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                font.pixelSize: 12; font.weight: 700
            }

            delegate: Rectangle {
                id: row
                required property int index
                required property string id
                required property string name
                required property string kind
                required property int unread
                required property bool mention
                required property string topic
                required property string avatar
                width: ListView.view.width
                height: 30; radius: Theme.radiusSm
                readonly property bool cursor: list.currentIndex === index
                // Not "open" while the Threads view covers the message pane — its
                // indicator would read as a second highlight next to the threads cursor.
                readonly property bool isOpen: id === Backend.currentChannelId && !Backend.threadsView
                // The prominent cursor highlight only when the sidebar itself is
                // the focused panel — otherwise the open channel shows just the
                // faint isOpen indicator (below), so it doesn't read as a live
                // cursor while you're navigating messages/threads.
                readonly property bool primary: sidebar.active && !sidebar.threadsSelected && cursor
                // Focus highlight matches the chat: subtle overlay + accent bar
                // (90ms / 120ms). Open channel stays faintly findable when the
                // cursor is elsewhere, but isn't a second "active" marker.
                color: primary ? Theme.selection
                     : (isOpen ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.06)
                               : hov.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : "transparent")

                Rectangle {
                    anchors.left: parent.left; anchors.leftMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3; height: 16; radius: 2; color: Theme.cursor
                    opacity: row.primary ? 1 : 0
                }

                // relative line number (vim hybrid: absolute on cursor row),
                // shown only while the sidebar is focused — drives N j/k jumps.
                Text { renderType: Text.QtRendering
                    visible: sidebar.active
                    anchors.left: parent.left; anchors.leftMargin: 6
                    width: 18; horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.cursor ? (row.index + 1) : Math.abs(row.index - list.currentIndex)
                    color: Theme.fg
                    opacity: row.cursor ? 1 : 0.65   // dim non-cursor, but still white & legible
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                    font.pixelSize: 12
                }

                Row {
                    anchors.fill: parent; anchors.leftMargin: sidebar.active ? 30 : 12
                    // reserve the badge's footprint on the right so long names
                    // elide before it instead of running underneath.
                    anchors.rightMargin: 8 + (row.unread > 0 ? 32 : 0)
                    spacing: 7
                    Item {
                        id: chIcon
                        anchors.verticalCenter: parent.verticalCenter
                        width: (row.kind === "dm" && row.avatar) ? 18 : 14
                        height: 18
                        Text { renderType: Text.QtRendering;
                            anchors.centerIn: parent
                            visible: !(row.kind === "dm" && dmAv.status === Image.Ready)
                            text: row.kind === "dm" ? "●" : "#"
                            color: row.kind === "dm" ? Theme.green : Theme.fg_muted
                            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: row.kind === "dm" ? 10 : 14
                        }
                        ClippingRectangle {
                            anchors.centerIn: parent; width: 18; height: 18; radius: 9
                            color: "transparent"; visible: row.kind === "dm"
                            Image {
                                id: dmAv; anchors.fill: parent
                                source: row.kind === "dm" ? (row.avatar || "") : ""
                                visible: status === Image.Ready
                                asynchronous: true; cache: true; fillMode: Image.PreserveAspectCrop
                                sourceSize.width: 36; sourceSize.height: 36
                            }
                        }
                    }
                    Text { renderType: Text.QtRendering;
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - chIcon.width - parent.spacing
                        text: row.name; elide: Text.ElideRight
                        color: (row.unread > 0 || row.isOpen || row.cursor) ? Theme.fg : Theme.dimmedFg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14
                        font.weight: row.unread > 0 ? 700 : Theme.fontWeight
                    }
                }

                Rectangle {
                    visible: row.unread > 0
                    anchors.right: parent.right; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    height: 17; width: Math.max(17, badge.implicitWidth + 10); radius: 9
                    // one consistent monochrome chip; mentions get an accent dot, not a color flip
                    color: Theme.hover
                    Text { renderType: Text.QtRendering;
                        id: badge; anchors.centerIn: parent; text: row.unread
                        color: Theme.fg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12; font.weight: 700
                    }
                }

                HoverHandler { id: hov }
                TapHandler { onTapped: { sidebar.threadsSelected = false; list.currentIndex = row.index; Backend.selectChannel(row.id, row.name, row.topic) } }
            }

            ScrollBar.vertical: ScrollBar { width: 6; policy: ScrollBar.AsNeeded }
        }
    }
}
