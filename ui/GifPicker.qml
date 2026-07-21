import QtQuick
import "."
import QsLib

// GIF browser overlay (Discord only). Opened by typing `/gif [query]` in the
// composer. Type to search (debounced against Discord's /gifs API); previews
// stream in as the daemon converts them. ctrl+h/j/k/l or arrows move the
// grid cursor; Enter sends the selected gif's page URL (the server unfurls
// it into the gifv embed); esc closes.
Item {
    id: picker
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 100 } }

    property bool open: false
    property int sel: 0
    property int gen: 0
    readonly property int cols: 3

    ListModel { id: gifs }

    function show(q) {
        search.text = q || ""
        open = true
        doSearch()
        Qt.callLater(() => search.forceActiveFocus())
    }
    function hide() { open = false; debounce.stop() }
    function doSearch() {
        gen = Backend.searchGifs(search.text.trim())
    }
    Timer { id: debounce; interval: 350; onTriggered: picker.doSearch() }

    Connections {
        target: Backend
        function onGifsReady(g, items) {
            if (!picker.open || g !== picker.gen) return
            gifs.clear()
            for (let i = 0; i < items.length; i++)
                gifs.append({ gid: String(items[i].id), title: items[i].title || "",
                              url: items[i].url || "", category: !!items[i].category, path: "" })
            picker.sel = 0
            grid.positionViewAtBeginning()
        }
        function onGifPreviewReady(g, id, path) {
            if (!picker.open || g !== picker.gen) return
            for (let i = 0; i < gifs.count; i++)
                if (gifs.get(i).gid === id) { gifs.setProperty(i, "path", path); break }
        }
    }

    function move(d) {
        if (gifs.count) sel = Math.max(0, Math.min(gifs.count - 1, sel + d))
        grid.positionViewAtIndex(sel, GridView.Contain)
    }
    function accept() {
        const g = gifs.get(sel)
        if (!g) return
        // a trending category tile drills into a search for its name; a real
        // gif sends its page url (the server unfurls it into the gifv embed)
        if (g.category) { search.text = g.title; doSearch(); return }
        if (!g.url) return
        hide()
        Backend.sendMessage(g.url)
    }

    MouseArea { anchors.fill: parent; onClicked: picker.hide() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.45 }

    Rectangle {
        width: Math.round(Math.min(560, parent.width - 80))
        height: header.height + grid.height + 12
        x: Math.round((parent.width - width) / 2)
        y: Math.round(parent.height * 0.12)
        radius: 24
        color: Theme.bg
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10); border.width: 1
        MouseArea { anchors.fill: parent }

        Column {
            anchors.fill: parent
            Item {
                id: header
                width: parent.width; height: 66
                Rectangle {
                    id: searchField
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    anchors.topMargin: 14; anchors.bottomMargin: 6
                    radius: 15
                    color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.07)
                }
                Row {
                    anchors.fill: searchField; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                    Icon {
                        name: "image"; width: 16; height: 16
                        color: Theme.fg_muted
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    TextInput {
                        id: search
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 36; color: Theme.fg; clip: true
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 16
                        onTextChanged: if (picker.open) debounce.restart()
                        Keys.onDownPressed: picker.move(picker.cols)
                        Keys.onUpPressed: picker.move(-picker.cols)
                        Keys.onLeftPressed: e => { if (cursorPosition === 0) picker.move(-1); else e.accepted = false }
                        Keys.onRightPressed: e => { if (cursorPosition === text.length) picker.move(1); else e.accepted = false }
                        Keys.onReturnPressed: picker.accept()
                        Keys.onEscapePressed: picker.hide()
                        Keys.onPressed: e => {
                            if (e.key === Qt.Key_Tab) { picker.accept(); e.accepted = true }
                            else if (e.modifiers & Qt.ControlModifier) {
                                if (e.key === Qt.Key_J) { picker.move(picker.cols); e.accepted = true }
                                else if (e.key === Qt.Key_K) { picker.move(-picker.cols); e.accepted = true }
                                else if (e.key === Qt.Key_H) { picker.move(-1); e.accepted = true }
                                else if (e.key === Qt.Key_L) { picker.move(1); e.accepted = true }
                            }
                        }
                        Text { visible: !search.text; text: "Search GIFs… (empty = trending)"
                               color: Theme.fg_muted; font: search.font }
                    }
                }
            }

            GridView {
                id: grid
                width: parent.width - 20
                x: 10
                height: Math.round(Math.min(430, Math.ceil(count / picker.cols) * cellHeight + 8))
                clip: true
                interactive: true
                cellWidth: Math.floor(width / picker.cols)
                cellHeight: 128
                model: gifs
                currentIndex: picker.sel
                ScrollFeel { flick: grid }
                delegate: Item {
                    required property int index
                    required property string gid
                    required property string title
                    required property string url
                    required property bool category
                    required property string path
                    width: grid.cellWidth; height: grid.cellHeight
                    Rectangle {
                        anchors.fill: parent; anchors.margins: 4
                        radius: Theme.radiusSm
                        color: Theme.surface
                        clip: true
                        border.width: picker.sel === index ? 2 : 0
                        border.color: Theme.cursor
                        AnimatedImage {
                            anchors.fill: parent; anchors.margins: picker.sel === index ? 2 : 0
                            visible: path !== ""
                            source: path
                            fillMode: Image.PreserveAspectCrop
                            playing: visible && picker.open
                            cache: false
                        }
                        // shimmer placeholder until the preview conversion lands
                        Text {
                            renderTypeQuality: Text.VeryHighRenderTypeQuality
                            visible: path === ""
                            anchors.centerIn: parent
                            text: "···"; color: Theme.fg_muted
                            font.family: Theme.fontFamily; font.pixelSize: 16
                            SequentialAnimation on opacity {
                                running: path === "" && picker.open; loops: Animation.Infinite
                                NumberAnimation { from: 0.9; to: 0.3; duration: 600 }
                                NumberAnimation { from: 0.3; to: 0.9; duration: 600 }
                            }
                        }
                        // category tiles: name label over a darkening scrim so
                        // it reads against any preview
                        Rectangle {
                            visible: category
                            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                            height: 26
                            gradient: Gradient {
                                GradientStop { position: 0; color: "transparent" }
                                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.55) }
                            }
                        }
                        Text {
                            visible: category
                            renderTypeQuality: Text.VeryHighRenderTypeQuality
                            anchors.left: parent.left; anchors.bottom: parent.bottom
                            anchors.leftMargin: 8; anchors.bottomMargin: 6
                            text: title
                            color: "white"
                            font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: 600
                            font.capitalization: Font.Capitalize
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: { picker.sel = index; picker.accept() } }
                    }
                }
            }
        }
    }
}
