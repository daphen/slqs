import QtQuick

// "What's new" modal shown before applying an update — lists the commit
// subjects between the running build and latest (Backend.updateChangelog).
// Shell-routed like KeybindHelp (no own focus): ↵ applies, j/k scroll,
// esc/q close. Only used when the daemon actually supplied a changelog.
Item {
    id: cl
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
    z: 104

    property bool open: false
    property var entries: []
    property string fromRev: ""
    property string toRev: ""

    function show() { open = true; Qt.callLater(() => list.positionViewAtBeginning()) }
    function close() { open = false }
    function scrollStep(d) {
        list.contentY = Math.max(0, Math.min(Math.max(0, list.contentHeight - list.height), list.contentY + d))
    }
    // half-page jump for ⌃d/⌃u — keeps long changelogs navigable on small screens
    function scrollPage(dir) { scrollStep(dir * Math.round(list.height * 0.85)) }

    MouseArea { anchors.fill: parent; onClicked: cl.close() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.45 }

    readonly property color panelBorder:
        Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)

    Rectangle {
        id: panel
        width: Math.round(Math.min(520, cl.width - 80))
        height: Math.round(Math.min(cl.height * 0.7, header.height + list.height + footer.height))
        anchors.centerIn: parent
        radius: 20
        color: Theme.bg
        border.color: cl.panelBorder; border.width: 1
        clip: true
        MouseArea { anchors.fill: parent }   // swallow clicks over the panel

        Column {
            anchors.fill: parent
            Item {
                id: header
                width: parent.width; height: 52
                Text {
                    anchors.left: parent.left; anchors.leftMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    text: "What's new"
                    color: Theme.fg
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 15; font.weight: 600
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    text: cl.fromRev + " → " + cl.toRev
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 12
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
            }
            ListView {
                id: list
                width: parent.width
                height: Math.round(Math.min(cl.height * 0.7 - header.height - footer.height, contentHeight))
                topMargin: 8; bottomMargin: 8
                clip: true
                model: cl.entries
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                delegate: Item {
                    required property var modelData
                    width: list.width; height: line.implicitHeight + 14
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: 20
                        anchors.right: parent.right; anchors.rightMargin: 20
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
            Item {
                id: footer
                width: parent.width; height: 40
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.hairline }
                Row {
                    anchors.centerIn: parent; spacing: 5
                    KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "↵" }
                    CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "update" }
                    Item { width: 10; height: 1 }
                    KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "esc" }
                    CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "cancel" }
                }
            }
        }
    }
}
