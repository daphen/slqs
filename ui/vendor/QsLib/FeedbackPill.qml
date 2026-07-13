// The family feedback pill ("Opening media…", "trashed — u undoes"):
// inverted ink chip, hairline ring, pulsing accent dot. Call show(text)
// for a transient toast or bind `active` for a persistent state.
import QtQuick

Rectangle {
    id: pill
    property alias text: label.text
    property bool active: false          // persistent mode (overrides timer)
    function show(msg) { label.text = msg; opacity = 1; hide.restart() }

    z: 201
    visible: opacity > 0
    opacity: active ? 1 : 0
    width: row.implicitWidth + 28
    height: 32
    radius: 8
    color: Theme.mode === "light" ? Theme.ink : Theme.fg
    border.width: 1
    border.color: Theme.hairline
    Behavior on opacity { NumberAnimation { duration: 140 } }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8
        Rectangle {
            width: 8; height: 8; radius: 4
            color: Theme.cursor
            anchors.verticalCenter: parent.verticalCenter
            SequentialAnimation on opacity {
                running: pill.visible
                loops: Animation.Infinite
                NumberAnimation { from: 1; to: 0.25; duration: 550 }
                NumberAnimation { from: 0.25; to: 1; duration: 550 }
            }
        }
        Text {
            id: label
            renderType: Text.NativeRendering
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.bg
            font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 13
        }
    }
    Timer { id: hide; interval: 3000; onTriggered: if (!pill.active) pill.opacity = 0 }
}
