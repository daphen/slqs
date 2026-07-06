import QtQuick
import "."

// Small modal confirmation. ask(preview) shows it; Enter/y confirms, Esc/n
// cancels. Grabs key focus so the main router doesn't see the keys.
Item {
    id: dlg
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 90 } }

    property bool open: false
    property string title: "Delete this message?"
    property string preview: ""
    signal confirmed()

    function ask(text) { preview = text; open = true; Qt.callLater(() => scope.forceActiveFocus()) }
    function close() { open = false }

    MouseArea { anchors.fill: parent; onClicked: dlg.close() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.5 }

    FocusScope {
        id: scope
        anchors.fill: parent
        Keys.onPressed: e => {
            if (e.key === Qt.Key_Y || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                dlg.confirmed(); dlg.close(); e.accepted = true
            } else if (e.key === Qt.Key_N || e.key === Qt.Key_Escape) {
                dlg.close(); e.accepted = true
            }
        }
        Rectangle {
            anchors.centerIn: parent
            width: Math.round(Math.min(440, parent.width - 80))
            height: col.implicitHeight + 36
            radius: Theme.radius; color: Theme.bg_alt
            border.color: Theme.hairline; border.width: 1
            MouseArea { anchors.fill: parent }   // swallow clicks
            Column {
                id: col
                anchors.centerIn: parent; width: parent.width - 36; spacing: 12
                Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; width: parent.width; wrapMode: Text.Wrap
                       text: dlg.title; color: Theme.fg
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 16; font.weight: 600 }
                Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; visible: dlg.preview.length > 0
                       width: parent.width; wrapMode: Text.Wrap; maximumLineCount: 4; elide: Text.ElideRight
                       text: dlg.preview; color: Theme.fg_muted
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14 }
                Row {
                    spacing: 16
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; text: "⏎ / y  delete"; color: Theme.fg
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13; font.weight: 600 }
                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality; text: "esc / n  cancel"; color: Theme.fg_muted
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13 }
                }
            }
        }
    }
}
