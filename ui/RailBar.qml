import QtQuick
import Quickshell.Widgets
import "."
import QsLib

// Vertical workspace rail (Discord-style). One rounded tile per workspace,
// initials as the glyph; the active one is filled with an accent pill on the
// left edge. Click or Ctrl+H/L (handled in shell) to switch.
Rectangle {
    id: rail
    color: "transparent"

    function glyphFor(ws) {
        if (ws.id === "@me") return String.fromCharCode(0xf086)   // nf-fa-comments (chat bubbles) for DMs
        const parts = (ws.name || "?").split(/[ ._\-]+/).filter(p => p.length)
        if (!parts.length) return "?"
        if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
        return (parts[0][0] + parts[1][0]).toUpperCase()
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top; anchors.topMargin: 10
        spacing: 8

        Repeater {
            model: Backend.workspaces
            delegate: Rectangle {
                required property var modelData
                readonly property bool active: modelData.id === Backend.currentWorkspace
                width: 40; height: 40; radius: active ? 12 : 20
                color: active ? Theme.selection : tileHov.hovered ? Theme.hover : Theme.hover
                Behavior on radius { NumberAnimation { duration: 110 } }
                Behavior on color { ColorAnimation { duration: 90 } }

                // accent pill on the left edge for the active workspace
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: -8
                    width: 3; radius: 2; color: Theme.fg
                    height: parent.active ? 24 : 0
                    Behavior on height { NumberAnimation { duration: 120 } }
                }

                Text { renderType: Text.QtRendering
                    anchors.centerIn: parent
                    text: rail.glyphFor(modelData)
                    color: parent.active ? Theme.fg : Theme.fg_muted
                    visible: icon.status !== Image.Ready
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: modelData.id === "@me" ? 18 : 13; font.weight: 500
                }
                ClippingRectangle {
                    anchors.fill: parent; color: "transparent"
                    radius: parent.radius
                    Behavior on radius { NumberAnimation { duration: 110 } }
                    Image {
                        id: icon
                        anchors.fill: parent
                        source: modelData.icon || ""
                        visible: status === Image.Ready
                        asynchronous: true; cache: true
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 80; sourceSize.height: 80
                    }
                }

                HoverHandler { id: tileHov }
                TapHandler { onTapped: Backend.switchWorkspace(modelData.id) }
            }
        }
    }
}
