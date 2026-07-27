import QtQuick
import QsLib

// Multi-link message → pick one to open (or open all). Built on the shared
// Modal shell (scroll/chrome/esc handled there). j/k move the cursor, ↵ opens
// the highlighted link, a opens all, 1-9 jump-open. The o keybind opens this
// only when a message carries ≥2 links; a single link opens directly.
Modal {
    id: lp
    property var links: []
    property int sel: 0
    signal chosen(string url)   // open one
    signal chosenAll()          // open every link (shell reads lp.links)
    panelWidth: Math.round(Math.min(680, lp.width - 80))
    maxHeightFrac: 0.6

    function openFor(urls) { links = urls; sel = 0; show() }

    header: Item {
        width: parent.width; height: 24
        Text {
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: "Open link"
            color: Theme.fg
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 15; font.weight: 600
        }
        Text {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: lp.links.length + " links"
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 12
        }
    }

    footer: Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 5
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "↵" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "open" }
        Item { width: 10; height: 1 }
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "a" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "all" }
        Item { width: 10; height: 1 }
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "esc" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "close" }
    }

    onKeyPressed: e => {
        if (e.key === Qt.Key_J || e.key === Qt.Key_Down) { lp.sel = Math.min(lp.sel + 1, lp.links.length - 1); e.accepted = true }
        else if (e.key === Qt.Key_K || e.key === Qt.Key_Up) { lp.sel = Math.max(lp.sel - 1, 0); e.accepted = true }
        else if (e.key === Qt.Key_A) { lp.chosenAll(); lp.close(); e.accepted = true }
        else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
            var i = e.key - Qt.Key_1
            if (i < lp.links.length) { lp.chosen(lp.links[i]); lp.close() }
            e.accepted = true
        }
    }
    onAccepted: { if (lp.links.length > 0) lp.chosen(lp.links[lp.sel]); lp.close() }

    Column {
        width: parent.width
        spacing: 2
        Repeater {
            model: lp.links
            delegate: Rectangle {
                required property int index
                required property var modelData
                width: parent.width
                height: url.implicitHeight + 14
                radius: Theme.radius
                color: index === lp.sel ? Theme.tintFill : "transparent"
                Row {
                    anchors.left: parent.left; anchors.leftMargin: 8
                    anchors.right: parent.right; anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Text {
                        width: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: (index + 1)
                        color: index === lp.sel ? Theme.fg : Theme.fg_muted
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 13; font.weight: 600
                    }
                    Text {
                        id: url
                        width: parent.width - 26
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData
                        color: index === lp.sel ? Theme.sky : Theme.fg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                        font.pixelSize: 13; elide: Text.ElideMiddle
                    }
                }
                TapHandler { onTapped: { lp.chosen(modelData); lp.close() } }
            }
        }
    }
}
