import QtQuick
import "."
import QsLib

// Voice-call indicator (dsqrd). The call itself runs in a hidden Helium driven
// by the daemon over CDP; this bar just reflects state and offers mute /
// disconnect. Visible only while in a call. Height collapses to 0 otherwise so
// it takes no space in the layout.
Rectangle {
    id: vb
    visible: Backend.callInCall
    height: visible ? 34 : 0
    color: Theme.surface0
    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.hairline }

    Row {
        anchors.left: parent.left; anchors.leftMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8
        Rectangle {
            width: 8; height: 8; radius: 4; color: Theme.green
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "In voice call" + (Backend.callMuted ? " · muted" : "")
            color: Theme.fg
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12
        }
    }

    Row {
        anchors.right: parent.right; anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        // mute toggle
        Rectangle {
            width: ml.implicitWidth + 18; height: 22; radius: 7
            color: Backend.callMuted ? Theme.red : Theme.surface
            border.color: Theme.hairline; border.width: 1
            anchors.verticalCenter: parent.verticalCenter
            Text { id: ml; anchors.centerIn: parent
                   text: Backend.callMuted ? "Unmute" : "Mute"; color: Theme.fg
                   font.family: Theme.fontFamily; font.pixelSize: 11 }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: Backend.voiceMute() }
        }
        // disconnect
        Rectangle {
            width: dl.implicitWidth + 18; height: 22; radius: 7
            color: Theme.surface; border.color: Theme.hairline; border.width: 1
            anchors.verticalCenter: parent.verticalCenter
            Text { id: dl; anchors.centerIn: parent; text: "Leave"; color: Theme.red
                   font.family: Theme.fontFamily; font.pixelSize: 11 }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: Backend.voiceLeave() }
        }
    }
}
