import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import "."

Rectangle {
    id: sidebar
    color: Theme.bg_alt
    property bool active: true   // is this the focused panel?
    // freeze channel-list reordering while the user navigates here
    onActiveChanged: Backend.sidebarNavigating = active
    Component.onCompleted: Backend.sidebarNavigating = active
    // Active panel gets the border (below); inactive dims slightly.
    opacity: active ? 1.0 : 0.8
    Behavior on opacity { NumberAnimation { duration: 120 } }
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
    // Star/unstar the cursor row; the rebuild reorders sections, so chase the
    // channel to its new position instead of letting the cursor dump to the top.
    function toggleStarCurrent() {
        if (threadsSelected) return
        const it = Backend.channels.get(list.currentIndex)
        if (!it) return
        const id = it.id
        Backend.toggleStar(id)
        for (let i = 0; i < Backend.channels.count; i++)
            if (Backend.channels.get(i).id === id) { list.currentIndex = i; break }
    }

    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.hairline }


    // Workspace switcher. Slack: tabs across the top. Discord (rail hidden):
    // a single current-workspace header that opens the Ctrl+S picker. Hidden
    // entirely when the vertical rail is shown. Same 52px band as the chat
    // header so the divider runs continuously across both panels.
    Item {
        id: wsHeader
        readonly property bool railShown: Backend.useRail && !Backend.railHidden
        visible: !railShown
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: railShown ? 0 : 52
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
        // Slack: workspace tabs
        Row {
            visible: !Backend.useRail
            anchors.left: parent.left; anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter; spacing: 4
                Repeater {
                    model: Backend.workspaces
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool active: modelData.id === Backend.currentWorkspace
                        height: 26; radius: 13
                        width: Math.min(tabLbl.implicitWidth + 20, 110)
                        // Snap, don't animate: a color fade on the active tab reads as a
                        // "blink" when switching workspaces (same reason the msg cursor snaps).
                        color: active ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.10) : tabHov.hovered ? Theme.hover : "transparent"
                        border.width: 1
                        border.color: active ? Theme.hairline : "transparent"
                        Text { id: tabLbl; renderType: Text.NativeRendering
                            anchors.centerIn: parent; width: parent.width - 12; elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData.name
                            color: active ? Theme.fg : Theme.fg_muted
                            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                            font.pixelSize: 14; font.weight: active ? 500 : 400
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
                anchors.leftMargin: 10; anchors.rightMargin: 10
                anchors.topMargin: 9; anchors.bottomMargin: 9
                color: wsHdrHov.hovered ? Theme.hover : "transparent"
                Row {
                    anchors.left: parent.left; anchors.leftMargin: 4
                    anchors.verticalCenter: parent.verticalCenter; spacing: 6
                    Text { renderType: Text.NativeRendering; anchors.verticalCenter: parent.verticalCenter
                        text: Backend.currentWorkspaceName || "Direct Messages"; color: Theme.fg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 15; font.weight: 500 }
                    Text { renderType: Text.NativeRendering; anchors.verticalCenter: parent.verticalCenter
                        text: "⌄"; color: Theme.fg_muted
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13 }
                }
                Text { renderType: Text.NativeRendering; anchors.right: parent.right; anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter; text: "⌃S"; color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 11 }
                HoverHandler { id: wsHdrHov }
                TapHandler { onTapped: sidebar.workspacePickerRequested() }
            }
    }

    Column {
        anchors.fill: parent
        anchors.topMargin: (wsHeader.visible ? wsHeader.height : 0) + 10
        anchors.leftMargin: 10; anchors.rightMargin: 10; anchors.bottomMargin: 10
        spacing: 10

        // Pinned "Threads" entry — opens the threads list (Ctrl+K palette).
        // Hidden when the backend has no threads (Discord).
        Rectangle {
            visible: Backend.hasThreads
            width: parent.width; height: Backend.hasThreads ? 36 : 0; clip: true; radius: height / 2
            readonly property bool thPrimary: sidebar.threadsSelected && sidebar.active
            // Reference style: the focused row is an inverted ink pill.
            color: thPrimary ? Theme.fg : thHov.hovered ? Theme.hover : "transparent"
            Row {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 7
                Text { renderType: Text.NativeRendering; anchors.verticalCenter: parent.verticalCenter
                       text: "↳"; color: parent.parent.thPrimary ? Theme.bg : Theme.fg_muted
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15 }
                Text { renderType: Text.NativeRendering; anchors.verticalCenter: parent.verticalCenter
                       text: "Threads"; color: parent.parent.thPrimary ? Theme.bg : Theme.fg
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                       font.pixelSize: 14; font.weight: Backend.threadUnreadTotal > 0 ? 500 : Theme.fontWeight }
            }
            Rectangle {
                visible: Backend.threadUnreadTotal > 0
                anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                height: 17; width: Math.max(17, tb.implicitWidth + 10); radius: 9; color: Theme.cursor
                Text { id: tb; renderType: Text.NativeRendering; anchors.centerIn: parent
                       text: Backend.threadUnreadTotal; color: Theme.ink
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                       font.pixelSize: 12; font.weight: 500 }
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
            // Reference rhythm: a hairline above each group, a full row of
            // air, then the tracked label sitting tight on its rows.
            section.delegate: Item {
                required property string section
                // The first group sits right under the Threads pill — the
                // between-groups air there double-counts with the Column
                // spacing, so it gets a tighter header.
                readonly property bool first:
                    Backend.channels.count > 0 && section === Backend.channels.get(0).section
                width: ListView.view.width
                height: first ? 30 : 48
                // Air on BOTH sides of the divider — flush pills read broken.
                // The first group draws no divider: the header band above
                // already provides the line, so one here reads as a stray.
                Rectangle {
                    visible: !first
                    anchors.top: parent.top; anchors.topMargin: 10
                    width: parent.width; height: 1
                    color: Theme.hairline
                }
                Text { renderType: Text.NativeRendering
                    anchors.left: parent.left; anchors.leftMargin: 12
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                    text: section.toUpperCase()
                    color: Theme.fg_muted; font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 11; font.weight: 500; font.letterSpacing: 1.2
                }
            }

            delegate: Item {
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
                height: 36
                readonly property bool cursor: list.currentIndex === index
                // Mentions and DMs are "loud" unreads — a filled accent badge,
                // not a quiet count. Section-agnostic, so starred and unstarred
                // rows render identically.
                readonly property bool loudUnread: unread > 0 && (mention || kind === "dm")
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
                // fg-relative tints, not the opaque selection: the sidebar is
                // translucent+blurred, so an absolute fill blends into the
                // backdrop while a tint always contrasts.
                // Reference style: the focused row is an inverted ink pill —
                // its own contrast is the cursor signal (no accent bar, no
                // hairpin). Idle open channel keeps the faint tint. Inner
                // rect: rows are full-bleed in the ListView, and a filled
                // pill needs the same inset the search field has.
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    radius: height / 2
                    color: row.primary ? Theme.fg
                         : (row.isOpen && !sidebar.active ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.06)
                                   : hov.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : "transparent")
                }

                // relative line number (vim hybrid: absolute on cursor row),
                // shown only while the sidebar is focused — drives N j/k jumps.
                Text { renderType: Text.NativeRendering
                    visible: sidebar.active && !row.cursor
                    anchors.left: parent.left; anchors.leftMargin: 12
                    width: 18; horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                    text: Math.abs(row.index - list.currentIndex)
                    color: row.primary ? Theme.bg : Theme.fg
                    opacity: 0.65
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 12
                    font.features: ({ "tnum": 1 })
                }
                // Cursor row: the same small accent bar the chat gutter uses,
                // centered in the number column.
                Rectangle {
                    visible: sidebar.active && row.cursor
                    anchors.left: parent.left; anchors.leftMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3; height: 16; radius: 2; color: Theme.cursor
                }

                Row {
                    anchors.fill: parent; anchors.leftMargin: sidebar.active ? 36 : 18
                    // reserve the badge's footprint on the right so long names
                    // elide before it instead of running underneath.
                    anchors.rightMargin: 8 + (row.unread > 0 ? 38 : 0)
                    spacing: 7
                    Item {
                        id: chIcon
                        anchors.verticalCenter: parent.verticalCenter
                        width: (row.kind === "dm" && row.avatar) ? 18 : 14
                        height: 18
                        Text { renderType: Text.NativeRendering;
                            anchors.centerIn: parent
                            visible: !(row.kind === "dm" && dmAv.status === Image.Ready)
                            text: row.kind === "dm" ? "●" : "#"
                            color: row.kind === "dm" ? Theme.green : (row.primary ? Theme.bg : Theme.fg_muted)
                            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: row.kind === "dm" ? 10 : 14
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
                    Text { renderType: Text.NativeRendering;
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - chIcon.width - parent.spacing
                        text: row.name; elide: Text.ElideRight
                        color: row.primary ? Theme.bg
                             : (row.unread > 0 || row.isOpen || row.cursor) ? Theme.fg : Theme.dimmedFg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14
                        font.weight: row.unread > 0 ? 500 : Theme.fontWeight
                    }
                }

                // Loud unread (mention / DM): filled accent pill, ink text —
                // stands out regardless of section, matching the Threads badge.
                Rectangle {
                    visible: row.loudUnread
                    anchors.right: parent.right; anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    height: 18; width: Math.max(18, ub.implicitWidth + 10); radius: 9
                    color: Theme.cursor
                    Text { id: ub; renderType: Text.NativeRendering; anchors.fill: parent
                           horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                           text: row.unread; color: Theme.ink
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                           font.pixelSize: 12; font.weight: 500; font.features: ({ "tnum": 1 }) }
                }
                // Quiet unread (plain channel): bare muted count, no chip — keeps
                // the row's two-level hierarchy for low-priority activity.
                Text { renderType: Text.NativeRendering
                    visible: row.unread > 0 && !row.loudUnread
                    anchors.right: parent.right; anchors.rightMargin: 22
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.unread
                    color: row.primary ? Theme.bg : Theme.fg_muted
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 13; font.weight: 400
                }

                HoverHandler { id: hov }
                TapHandler { onTapped: { sidebar.threadsSelected = false; list.currentIndex = row.index; Backend.selectChannel(row.id, row.name, row.topic) } }
            }

            ScrollBar.vertical: ScrollBar { width: 6; policy: ScrollBar.AsNeeded }
        }
    }
}
