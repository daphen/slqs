import QtQuick
import QsLib

// Summarize-while-away scope picker (Discord only). Same Modal family as
// LinkPicker. Two views: pick a scope (all-new / last day / last week / a
// person); choosing "from a person" swaps to the channel's participant list
// (Backend.searchUsers — the @-autocomplete source). ↵ chooses, j/k move,
// h/⌫ steps back from the participant view, esc closes.
Modal {
    id: sp
    property int mode: 0        // 0 = scope list, 1 = participant list
    property int sel: 0
    property var people: []
    signal chosen(string scope, string user)
    panelWidth: Math.round(Math.min(520, sp.width - 80))
    maxHeightFrac: 0.6
    panelColor: Theme.bg
    chinBar: true

    readonly property var scopes: [
        { key: "session",   label: "What's new (this conversation)" },
        { key: "all_new",   label: "All new (since last read)" },
        { key: "last_day",  label: "Last day" },
        { key: "last_week", label: "Last week" },
        { key: "user",      label: "From a specific person…" },
    ]
    readonly property var rows: mode === 0 ? scopes : people

    function start() { mode = 0; sel = 0; people = []; show() }

    function _choose() {
        if (mode === 0) {
            const s = scopes[sel]
            if (!s) return
            if (s.key === "user") { people = Backend.searchUsers("", 100); sel = 0; mode = 1; return }
            sp.chosen(s.key, ""); sp.close()
        } else {
            const p = people[sel]
            if (p) { sp.chosen("user", String(p.id)); sp.close() }
        }
    }

    header: Item {
        width: parent.width; height: 24
        Text {
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: sp.mode === 0 ? "Summarize" : "From which person?"
            color: Theme.fg
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 15; font.weight: 600
        }
        Text {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: sp.mode === 0 ? "what happened while away" : (sp.people.length + " people")
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 12
        }
    }

    footer: Item {
        width: parent.width; height: 42
        Row {
            anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 5
            KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "j" }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "k" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "move" }
            Item { width: 10; height: 1 }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "↵" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: sp.mode === 0 ? "summarize" : "pick" }
        }
        Row {
            anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 5
            KeyCap { visible: sp.mode === 1; anchors.verticalCenter: parent.verticalCenter; small: true; text: "h" }
            CapLabel { visible: sp.mode === 1; anchors.verticalCenter: parent.verticalCenter; text: "back" }
            Item { visible: sp.mode === 1; width: 10; height: 1 }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "esc" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "close" }
        }
    }

    onKeyPressed: e => {
        if (e.key === Qt.Key_J || e.key === Qt.Key_Down) { sp.sel = Math.min(sp.sel + 1, sp.rows.length - 1); e.accepted = true }
        else if (e.key === Qt.Key_K || e.key === Qt.Key_Up) { sp.sel = Math.max(sp.sel - 1, 0); e.accepted = true }
        else if ((e.key === Qt.Key_H || e.key === Qt.Key_Backspace) && sp.mode === 1) { sp.mode = 0; sp.sel = 0; e.accepted = true }
        else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
            var i = e.key - Qt.Key_1
            if (i < sp.rows.length) { sp.sel = i; sp._choose() }
            e.accepted = true
        }
    }
    onAccepted: sp._choose()

    Column {
        width: parent.width
        spacing: 1
        Repeater {
            model: sp.rows
            delegate: Item {
                id: row
                required property int index
                required property var modelData
                width: parent.width
                height: 40
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 4; anchors.rightMargin: 4
                    anchors.topMargin: 1; anchors.bottomMargin: 1
                    radius: 13
                    color: row.index === sp.sel ? Theme.selection : hov.hovered ? Theme.surface : "transparent"
                    border.width: 1
                    border.color: row.index === sp.sel ? Theme.hairline : "transparent"
                }
                Text {
                    anchors.left: parent.left; anchors.leftMargin: 18
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 36
                    text: sp.mode === 0 ? row.modelData.label : ("@" + (row.modelData.name || "someone"))
                    color: row.index === sp.sel ? Theme.fg : Theme.fg_secondary
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 14; elide: Text.ElideRight
                }
                HoverHandler { id: hov }
                TapHandler { onTapped: { sp.sel = row.index; sp._choose() } }
            }
        }
    }
}
