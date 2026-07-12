import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import "."
import QsLib

// Full-pane "Threads" view: a scannable list of every followed thread with
// its channel, author, preview, reply count, unread and last activity.
// j/k navigate, Enter opens the thread in the side panel. The cursor shows
// while this page is focused and no thread panel has taken over.
Item {
    id: page
    property bool active: false
    property alias currentIndex: list.currentIndex

    Rectangle { anchors.fill: parent; color: Theme.bg_alt }   // opaque (covers channel view)

    function move(d) {
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + d))
        list.positionViewAtIndex(list.currentIndex, ListView.Contain)
    }
    function toTop()    { list.currentIndex = 0; list.positionViewAtBeginning() }
    function toBottom() { list.currentIndex = list.count - 1; list.positionViewAtEnd() }
    function half(d)    { move(d * 6) }
    function openCurrent() {
        const t = Backend.currentSubThreads[list.currentIndex]
        if (t) Backend.openThreadFromSub(t)
    }

    Rectangle {
        id: head
        width: parent.width; height: 52; color: "transparent"
        Row {
            anchors.left: parent.left; anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter; spacing: 9
            Text { renderType: Text.NativeRendering; text: "↳"; color: Theme.fg_muted
                   anchors.verticalCenter: parent.verticalCenter
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17 }
            Text { renderType: Text.NativeRendering; text: "Threads"; color: Theme.fg
                   anchors.verticalCenter: parent.verticalCenter
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17; font.weight: 500 }
            Text { renderType: Text.NativeRendering; text: Backend.currentSubThreads.length + " followed"
                   color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14 }
        }
    }

    Card {
        id: threadsCard
        anchors { top: head.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
                  topMargin: 6; leftMargin: 4; rightMargin: 12; bottomMargin: 12 }
    }

    ListView {
        id: list
        anchors.fill: threadsCard
        clip: true
        topMargin: 8; bottomMargin: 10; spacing: 8
        model: Backend.currentSubThreads
        currentIndex: 0
        highlightFollowsCurrentItem: false
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 2000; reuseItems: true

        ScrollFeel { flick: list }

        delegate: Item {
            id: row
            required property var modelData
            required property int index
            width: list.width
            height: card.height
            readonly property bool cursor: index === list.currentIndex && page.active

            Rectangle {
            id: card
            anchors.left: parent.left; anchors.right: parent.right
            anchors.leftMargin: 18; anchors.rightMargin: 18
            height: col.implicitHeight + 24
            radius: Theme.radius
            color: row.cursor ? Theme.selection : hov.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : Theme.surface
            border.color: row.cursor ? Theme.fg : Theme.hairline
            border.width: row.cursor ? 2 : 1

            Column {
                id: col
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: parent.top; anchors.margins: 12
                spacing: 6

                // header line: avatar, author, channel, time, unread
                Item {
                    width: parent.width; height: 28
                    Row {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                        // Text OUTSIDE the clip: ClippingRectangle rasterizes children
                        // at 1x DPR, blurring glyphs on a fractional-scale monitor.
                        Rectangle {
                            width: 24; height: 24; radius: 6; color: modelData.color || Theme.surface
                            anchors.verticalCenter: parent.verticalCenter
                            Text { renderType: Text.NativeRendering; anchors.centerIn: parent
                                   visible: img.status !== Image.Ready
                                   text: modelData.initials || "?"; color: Theme.ink
                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 11; font.weight: 500 }
                            ClippingRectangle {
                                anchors.fill: parent; radius: parent.radius; color: "transparent"
                                Image { id: img; anchors.fill: parent; source: modelData.avatar || ""
                                        visible: status === Image.Ready; asynchronous: true; cache: true
                                        fillMode: Image.PreserveAspectCrop; sourceSize.width: 48; sourceSize.height: 48 }
                            }
                        }
                        Text { renderType: Text.NativeRendering; anchors.verticalCenter: parent.verticalCenter
                               text: modelData.title || ""; color: Theme.mode === "light" ? Theme.ink : Theme.fg
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15; font.weight: 500 }
                        Text { renderType: Text.NativeRendering; anchors.verticalCenter: parent.verticalCenter
                               text: "#" + (modelData.channelName || ""); color: Theme.fg_muted
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13 }
                    }
                    Text { renderType: Text.NativeRendering
                           anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                           text: modelData.lastTime || ""; color: Theme.fg_muted
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12 }
                }

                // parent preview
                Text { renderType: Text.NativeRendering
                       width: parent.width; text: modelData.preview || ""
                       color: Theme.mode === "light" ? Theme.fg_muted : Theme.fg_secondary; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14 }

                // footer: reply count + unread
                Row {
                    spacing: 10
                    Text { renderType: Text.NativeRendering
                           text: (modelData.replyCount || 0) + (modelData.replyCount === 1 ? " reply" : " replies")
                           color: Theme.sky
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13; font.weight: 500 }
                    Text { renderType: Text.NativeRendering; visible: (modelData.unread || 0) > 0
                           text: modelData.unread + " new"; color: Theme.cursor
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13; font.weight: 500 }
                }
            }

            HoverHandler { id: hov }
            TapHandler { onTapped: { list.currentIndex = row.index; Backend.openThreadFromSub(row.modelData) } }
            }
        }

        ScrollBar.vertical: ScrollBar { width: 8; policy: ScrollBar.AsNeeded }

        // empty state
        Text {
            renderType: Text.NativeRendering
            anchors.centerIn: parent; visible: list.count === 0
            text: "No followed threads"; color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15
        }
    }
}
