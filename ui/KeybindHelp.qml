import QtQuick
import "."
import QsLib

// Normal-mode `?` cheat sheet. Built live from shell.qml's `keymaps` so it can
// never drift from the real bindings. App-aware via Backend: slqs shows the
// THREADS section + "workspace" wording; dsqrd drops THREADS + says "server".
// Responsive column count; `/` fuzzy-filters; esc/q/? closes.
Item {
    id: sheet
    anchors.fill: parent
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 90 } }

    property bool open: false
    property var keymaps: ({})          // win.keymaps
    property string query: ""
    property bool searching: false

    // Presentational only — shell.qml's routeKey owns open/close/filter and sets
    // open/searching/query; the field below just displays `query`.
    function show() { open = true; resetSearch() }
    function close() { open = false }
    function resetSearch() { searching = false; query = "" }

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
            case "ctrl+shift+r": return "^⇧r"
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

    readonly property var allSections: {
        const S = [
            { title: "NAVIGATE", rows: _rows([["channel", "nav"]], [{ keys: "{n}j", help: "Repeat n times (count prefix)" }]) },
            { title: "CHATS",    rows: _rows([["channel", "chats"]], null) },
        ]
        if (Backend.hasThreads)
            S.push({ title: "THREADS", rows: _rows([["thread", "thread"], ["threadsPage", "thread"]], null) })
        S.push({ title: "MESSAGES",        rows: _rows([["channel", "msg"]], null) })
        S.push({ title: "VIEWS & GENERAL", rows: _rows([["channel", "view"]], [{ keys: "q", help: "Close panel / overlay" }]) })
        return S
    }

    // Sections with rows filtered by the query (match help or keys); empties drop.
    readonly property var filtered: {
        const q = query.trim().toLowerCase()
        if (!q) return allSections
        const out = []
        for (const s of allSections) {
            const rows = s.rows.filter(r =>
                r.help.toLowerCase().indexOf(q) >= 0
                || r.keys.toLowerCase().indexOf(q) >= 0
                || s.title.toLowerCase().indexOf(q) >= 0)
            if (rows.length) out.push({ title: s.title, rows: rows })
        }
        return out
    }

    // 1 / 2 / 3 columns by available width; sections packed into the shortest.
    readonly property int colCount: sheet.width < 620 ? 1 : sheet.width < 940 ? 2 : 3
    readonly property var laidOut: {
        const cols = [], load = []
        for (let i = 0; i < colCount; i++) { cols.push([]); load.push(0) }
        for (const s of filtered) {
            let t = 0
            for (let i = 1; i < colCount; i++) if (load[i] < load[t]) t = i
            cols[t].push(s)
            load[t] += s.rows.length + 2
        }
        return cols
    }

    MouseArea { anchors.fill: parent; onClicked: sheet.close() }
    Rectangle { anchors.fill: parent; color: Theme.ink; opacity: 0.5 }

    Item {
        anchors.fill: parent
        Rectangle {
            id: panel
            anchors.centerIn: parent
            width: Math.min(sheet.colCount === 1 ? 420 : sheet.colCount === 2 ? 760 : 1040, parent.width - 60)
            height: Math.min(body.implicitHeight + 56, parent.height - 60)
            radius: Theme.radius; color: Theme.bg_alt
            border.color: Theme.hairline; border.width: 1
            clip: true
            MouseArea { anchors.fill: parent }   // swallow clicks inside the panel

            Column {
                id: body
                anchors.fill: parent; anchors.margins: 28
                spacing: 20
                // header: title + search pill
                Item {
                    width: parent.width; height: 30
                    Text { renderType: Text.NativeRendering
                           anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                           text: "Keybindings"; color: Theme.fg
                           font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                           font.pixelSize: 20; font.bold: true }
                    Rectangle {
                        readonly property bool showField: sheet.searching || sheet.query.length > 0
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        width: showField ? 220 : 0
                        height: 30; radius: 8; clip: true
                        color: Theme.surface
                        border.width: showField ? 1 : 0; border.color: Theme.hairline
                        visible: width > 1
                        Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        Text {   // display-only: shell.qml edits sheet.query
                            anchors.fill: parent; anchors.margins: 8
                            verticalAlignment: Text.AlignVCenter
                            text: sheet.query.length ? sheet.query : "filter…"
                            color: sheet.query.length ? Theme.fg : Theme.fg_muted
                            font.family: Theme.fontFamily; font.pixelSize: 13
                            elide: Text.ElideLeft
                            renderType: Text.NativeRendering
                        }
                    }
                }

                Row {
                    spacing: 40
                    Repeater {
                        model: sheet.laidOut
                        Column {
                            id: colRoot
                            required property var modelData
                            width: (body.width - 40 * (sheet.colCount - 1)) / sheet.colCount
                            spacing: 18
                            Repeater {
                                model: colRoot.modelData
                                Column {
                                    id: secRoot
                                    required property var modelData
                                    width: colRoot.width
                                    spacing: 6
                                    Text { renderType: Text.NativeRendering
                                           text: secRoot.modelData.title; color: Theme.fg_muted
                                           font.family: Theme.fontFamily; font.pixelSize: 11; font.letterSpacing: 1 }
                                    Repeater {
                                        model: secRoot.modelData.rows
                                        Row {
                                            id: rowRoot
                                            required property var modelData
                                            width: parent.width
                                            spacing: 12
                                            Rectangle {
                                                width: 76; height: 24; radius: Theme.radiusSm
                                                color: Theme.surface; border.color: Theme.hairline; border.width: 1
                                                Text { renderType: Text.NativeRendering
                                                       anchors.centerIn: parent; text: rowRoot.modelData.keys; color: Theme.fg
                                                       font.family: Theme.fontFamily; font.pixelSize: 13 }
                                            }
                                            Text { renderType: Text.NativeRendering
                                                   anchors.verticalCenter: parent.verticalCenter
                                                   width: parent.width - 76 - parent.spacing
                                                   text: rowRoot.modelData.help; color: Theme.fg; elide: Text.ElideRight
                                                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14 }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Text { renderType: Text.NativeRendering
                       visible: sheet.filtered.length === 0
                       text: "no keys match “" + sheet.query + "”"; color: Theme.fg_muted
                       font.family: Theme.fontFamily; font.pixelSize: 13 }
                Text { renderType: Text.NativeRendering
                       anchors.horizontalCenter: parent.horizontalCenter
                       text: sheet.searching ? "type to filter · esc to clear" : "/ to search · esc, q or ? to close"
                       color: Theme.fg_muted
                       font.family: Theme.fontFamily; font.pixelSize: 12 }
            }
        }
    }
}
