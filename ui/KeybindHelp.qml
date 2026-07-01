import QtQuick
import "."

// Normal-mode `?` cheat sheet. Built live from shell.qml's `keymaps` so it can
// never drift from the real bindings. App-aware via Backend: slqs shows the
// THREADS section + "workspace" wording; dsqrd drops THREADS + says "server".
Item {
    id: sheet
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 90 } }

    property bool open: false
    property var keymaps: ({})          // win.keymaps

    function show() { open = true; Qt.callLater(() => scope.forceActiveFocus()) }
    function close() { open = false }

    function _help(h) { return (typeof h === "function") ? h() : h }
    function _pretty(id) {
        switch (id) {
            case "enter":     return "⏎"
            case "tab":       return "⇥"
            case "shift+tab": return "⇧⇥"
            case "ctrl+d": return "^d"; case "ctrl+u": return "^u"
            case "ctrl+e": return "^e"; case "ctrl+y": return "^y"
            case "ctrl+g": return "^g"; case "ctrl+k": return "^k"
            case "ctrl+s": return "^s"; case "ctrl+h": return "^h"; case "ctrl+l": return "^l"
        }
        return id
    }
    // Collect {keys, help} rows for the given (mode, cat) pairs, in table order,
    // then append any static extras.
    function _rows(picks, extra) {
        const rows = []
        for (let p = 0; p < picks.length; p++) {
            const tbl = keymaps[picks[p][0]] || ({}), cat = picks[p][1]
            for (const id in tbl) {
                const e = tbl[id]
                // Empty help = app-gated bind hidden in this app (e.g. slqs-only
                // people actions in dsqrd) — skip so the sheet stays honest.
                if (e && e.cat === cat && _help(e.help)) rows.push({ keys: _pretty(id), help: _help(e.help) })
            }
        }
        if (extra) for (let i = 0; i < extra.length; i++) rows.push(extra[i])
        return rows
    }

    readonly property var leftCols: {
        const L = [
            { title: "NAVIGATE", rows: _rows([["channel", "nav"]], [{ keys: "{n}j", help: "Repeat n times (count prefix)" }]) },
            { title: "CHATS",    rows: _rows([["channel", "chats"]], null) },
        ]
        if (Backend.hasThreads)
            L.push({ title: "THREADS", rows: _rows([["thread", "thread"], ["threadsPage", "thread"]], null) })
        return L
    }
    readonly property var rightCols: [
        { title: "MESSAGES",        rows: _rows([["channel", "msg"]], null) },
        { title: "VIEWS & GENERAL", rows: _rows([["channel", "view"]], [{ keys: "q", help: "Close panel / overlay" }]) },
    ]

    MouseArea { anchors.fill: parent; onClicked: sheet.close() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.5 }

    FocusScope {
        id: scope
        anchors.fill: parent
        Keys.onPressed: e => {
            if (e.key === Qt.Key_Escape || e.key === Qt.Key_Q || e.text === "?") { sheet.close(); e.accepted = true }
        }
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(824, parent.width - 80)
            height: body.implicitHeight + 56
            radius: Theme.radius; color: Theme.bg_alt
            border.color: Theme.hairline; border.width: 1
            MouseArea { anchors.fill: parent }   // swallow clicks inside the panel

            Column {
                id: body
                anchors.fill: parent; anchors.margins: 28
                spacing: 22
                Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                       text: "Keybindings"; color: Theme.fg
                       font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                       font.pixelSize: 20; font.bold: true }
                Row {
                    spacing: 48
                    Repeater {
                        model: [sheet.leftCols, sheet.rightCols]
                        Column {
                            id: colRoot
                            required property var modelData
                            width: 360
                            spacing: 18
                            Repeater {
                                model: colRoot.modelData
                                Column {
                                    id: secRoot
                                    required property var modelData
                                    width: colRoot.width
                                    spacing: 6
                                    Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                                           text: secRoot.modelData.title; color: Theme.fg_muted
                                           font.family: Theme.fontFamily; font.pixelSize: 11; font.letterSpacing: 1 }
                                    Repeater {
                                        model: secRoot.modelData.rows
                                        Row {
                                            id: rowRoot
                                            required property var modelData
                                            spacing: 12
                                            Rectangle {
                                                width: 76; height: 24; radius: Theme.radiusSm
                                                color: Theme.surface; border.color: Theme.hairline; border.width: 1
                                                Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                                                       anchors.centerIn: parent; text: rowRoot.modelData.keys; color: Theme.fg
                                                       font.family: Theme.fontFamily; font.pixelSize: 13 }
                                            }
                                            Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                                                   anchors.verticalCenter: parent.verticalCenter
                                                   text: rowRoot.modelData.help; color: Theme.fg
                                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14 }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Text { renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                       anchors.horizontalCenter: parent.horizontalCenter
                       text: "press ?, esc or q to close"; color: Theme.fg_muted
                       font.family: Theme.fontFamily; font.pixelSize: 12 }
            }
        }
    }
}
