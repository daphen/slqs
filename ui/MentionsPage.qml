import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import "."
import QsLib

// Full-pane "Mentions" view: every recent message that mentions you —
// direct @you, @here/@channel/@everyone, or a user group — thread replies
// included, newest first. This is where mentions buried in threads you
// don't follow become findable. Enter jumps to the message (opening the
// thread panel when it lives in one).
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
        const m = Backend.currentMentions[list.currentIndex]
        if (m) Backend.openMention(m)
    }

    Rectangle {
        id: head
        width: parent.width; height: 52; color: "transparent"
        Row {
            anchors.left: parent.left; anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter; spacing: 9
            Text { renderType: Text.NativeRendering; text: "@"; color: Theme.fg_muted
                   anchors.verticalCenter: parent.verticalCenter
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17 }
            Text { renderType: Text.NativeRendering; text: "Mentions"; color: Theme.fg
                   anchors.verticalCenter: parent.verticalCenter
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 17; font.weight: 500 }
            Text { renderType: Text.NativeRendering; text: Backend.currentMentions.length + " recent"
                   color: Theme.fg_muted; anchors.verticalCenter: parent.verticalCenter
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14 }
        }
    }

    Card {
        id: mentionsCard
        anchors { top: head.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
                  topMargin: 6; leftMargin: 4; rightMargin: 12; bottomMargin: 12 }
    }

    ListView {
        id: list
        anchors.fill: mentionsCard
        clip: true
        topMargin: 8; bottomMargin: 10; spacing: 8
        model: Backend.currentMentions
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

                // header line: avatar, author, channel, time
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
                        Text { renderType: Text.NativeRendering; anchors.verticalCenter: parent.verticalCenter
                               visible: !!modelData.inThread
                               text: "↳ in thread"; color: Theme.sky
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12; font.weight: 500 }
                    }
                    Text { renderType: Text.NativeRendering
                           anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                           text: modelData.lastTime || ""; color: Theme.fg_muted
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12 }
                }

                // the mentioning message
                Text { renderType: Text.NativeRendering
                       width: parent.width; text: modelData.preview || ""
                       color: Theme.mode === "light" ? Theme.fg_muted : Theme.fg_secondary; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14 }
            }

            HoverHandler { id: hov }
            TapHandler { onTapped: { list.currentIndex = row.index; Backend.openMention(row.modelData) } }
            }
        }

        ScrollBar.vertical: ScrollBar { width: 8; policy: ScrollBar.AsNeeded }

        // empty state
        Text {
            renderType: Text.NativeRendering
            anchors.centerIn: parent; visible: list.count === 0
            text: "No recent mentions"; color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15
        }
    }
}
