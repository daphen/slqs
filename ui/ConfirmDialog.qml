import QtQuick
import "."
import QsLib

// Small modal confirmation on the QsLib Modal shell. ask(preview) shows it;
// ↵/y confirms, esc/n/q cancels. A long preview scrolls (no line cap) since the
// scaffold gives the body a Flickable.
Modal {
    id: dlg
    z: 104
    panelWidth: Math.round(Math.min(440, dlg.width - 80))
    maxHeightFrac: 0.6

    property string title: "Delete this message?"
    property string preview: ""
    signal confirmed()

    function ask(text) { preview = text; show() }

    onAccepted: { dlg.confirmed(); dlg.close() }
    onKeyPressed: e => {
        if (e.key === Qt.Key_Y) { dlg.confirmed(); dlg.close(); e.accepted = true }
        else if (e.key === Qt.Key_N) { dlg.close(); e.accepted = true }
    }

    header: Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: dlg.title; color: Theme.fg
        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
        font.pixelSize: 16; font.weight: 500
    }

    footer: Row {
        spacing: 16
        Text { text: "⏎ / y  delete"; color: Theme.fg
               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13; font.weight: 500 }
        Text { text: "esc / n  cancel"; color: Theme.fg_muted
               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13 }
    }

    Text {
        visible: dlg.preview.length > 0
        width: parent.width; wrapMode: Text.Wrap
        text: dlg.preview; color: Theme.fg_muted
        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14
    }
}
