import QtQuick

// "What's new" modal — the Changelog: commit trailers between the running build
// and latest (Backend.updateChangelog). Built on the shared Modal shell (scroll,
// keys, chrome handled there); ↵ emits accepted(), which the shell wires to
// Backend.applyUpdate. Only used when the daemon actually supplied a changelog.
Modal {
    id: cl
    property var entries: []
    property string fromRev: ""
    property string toRev: ""
    panelWidth: Math.round(Math.min(520, cl.width - 80))
    maxHeightFrac: 0.7

    header: Item {
        width: parent.width
        height: 32
        Text {
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: "What's new"
            color: Theme.fg
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 15; font.weight: 600
        }
        Text {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: cl.fromRev + " → " + cl.toRev
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 12
        }
    }

    footer: Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 5
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "↵" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "update" }
        Item { width: 10; height: 1 }
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "esc" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "cancel" }
    }

    Column {
        width: parent.width
        Repeater {
            model: cl.entries
            delegate: Item {
                required property var modelData
                width: parent.width
                height: line.implicitHeight + 14
                Row {
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Rectangle {
                        width: 5; height: 5; radius: 2.5; color: Theme.cursor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        id: line
                        width: parent.width - 15
                        text: modelData
                        color: Theme.fg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 13; wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
