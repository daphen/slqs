import QtQuick
import QsLib

// Discord "agent" menu (the `c` key). Pick a range, then either summarize it
// (↵) or ask a free-text question about it (a). Views:
//   mode 0 — range list (session / all-new / last day / last week / a person)
//   mode 1 — participant list (when the range is "a person")
//   mode 2 — question input (after pressing `a` on a chosen range)
// ↵ chooses, j/k move, a asks, h/⌫ steps back, esc closes.
Modal {
    id: sp
    property int mode: 0
    property int sel: 0
    property var people: []
    property bool asking: false          // true once `a` started an ask flow
    property string pendingScope: ""     // range captured for the ask
    property string pendingUser: ""
    property string pendingUserName: ""
    signal chosen(string scope, string user)
    signal asked(string scope, string user, string question)
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
    readonly property var rows: mode === 0 ? scopes : (mode === 1 ? people : [])

    function start() {
        mode = 0; sel = 0; people = []
        asking = false; pendingScope = ""; pendingUser = ""; pendingUserName = ""
        show()
    }

    function _pendingLabel() {
        if (pendingScope === "user") return "@" + (pendingUserName || "someone")
        for (var i = 0; i < scopes.length; i++) if (scopes[i].key === pendingScope) return scopes[i].label
        return ""
    }
    function _toAsk() { mode = 2; questionInput.text = ""; Qt.callLater(() => questionInput.forceActiveFocus()) }
    function _submitAsk() {
        const q = questionInput.text.trim()
        if (!q.length) return
        sp.asked(pendingScope, pendingUser, q); sp.close()
    }

    // ↵ — summarize (or, mid ask-flow, advance to the question)
    function _choose() {
        if (mode === 0) {
            const s = scopes[sel]; if (!s) return
            if (s.key === "user") { people = Backend.searchUsers("", 100); sel = 0; mode = 1; return }
            if (asking) { pendingScope = s.key; _toAsk(); return }
            sp.chosen(s.key, ""); sp.close()
        } else if (mode === 1) {
            const p = people[sel]; if (!p) return
            if (asking) { pendingScope = "user"; pendingUser = String(p.id); pendingUserName = p.name || ""; _toAsk(); return }
            sp.chosen("user", String(p.id)); sp.close()
        }
    }

    // a — ask a question about the highlighted range
    function _ask() {
        if (mode === 0) {
            const s = scopes[sel]; if (!s) return
            asking = true
            if (s.key === "user") { people = Backend.searchUsers("", 100); sel = 0; mode = 1; return }
            pendingScope = s.key; _toAsk()
        } else if (mode === 1) {
            const p = people[sel]; if (!p) return
            asking = true; pendingScope = "user"; pendingUser = String(p.id); pendingUserName = p.name || ""; _toAsk()
        }
    }

    header: Item {
        width: parent.width; height: 24
        Text {
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            text: sp.mode === 2 ? "Ask a question" : (sp.mode === 1 ? "From which person?" : "Agent")
            color: Theme.fg
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 15; font.weight: 600
        }
        Text {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            text: sp.mode === 2 ? ("range: " + sp._pendingLabel())
                 : (sp.mode === 1 ? (sp.people.length + " people") : "summarize or ask")
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 12; elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width * 0.6)
        }
    }

    footer: Item {
        width: parent.width; height: 42
        Row {
            anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 5
            KeyCap { visible: sp.mode !== 2; anchors.verticalCenter: parent.verticalCenter; small: true; text: "j" }
            KeyCap { visible: sp.mode !== 2; anchors.verticalCenter: parent.verticalCenter; small: true; text: "k" }
            CapLabel { visible: sp.mode !== 2; anchors.verticalCenter: parent.verticalCenter; text: "move" }
            Item { visible: sp.mode !== 2; width: 10; height: 1 }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "↵" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: sp.mode === 2 ? "ask" : "summarize" }
            Item { visible: sp.mode !== 2; width: 10; height: 1 }
            KeyCap { visible: sp.mode !== 2; anchors.verticalCenter: parent.verticalCenter; small: true; text: "a" }
            CapLabel { visible: sp.mode !== 2; anchors.verticalCenter: parent.verticalCenter; text: "ask" }
        }
        Row {
            anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 5
            KeyCap { visible: sp.mode === 1; anchors.verticalCenter: parent.verticalCenter; small: true; text: "h" }
            CapLabel { visible: sp.mode === 1; anchors.verticalCenter: parent.verticalCenter; text: "back" }
            Item { visible: sp.mode === 1; width: 10; height: 1 }
            KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "esc" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: sp.mode === 2 ? "back" : "close" }
        }
    }

    onKeyPressed: e => {
        if (sp.mode === 2) return   // the question field owns the keyboard
        if (e.key === Qt.Key_J || e.key === Qt.Key_Down) { sp.sel = Math.min(sp.sel + 1, sp.rows.length - 1); e.accepted = true }
        else if (e.key === Qt.Key_K || e.key === Qt.Key_Up) { sp.sel = Math.max(sp.sel - 1, 0); e.accepted = true }
        else if ((e.key === Qt.Key_H || e.key === Qt.Key_Backspace) && sp.mode === 1) { sp.mode = 0; sp.sel = 0; sp.asking = false; e.accepted = true }
        else if (e.key === Qt.Key_A) { sp._ask(); e.accepted = true }
        else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
            var i = e.key - Qt.Key_1
            if (i < sp.rows.length) { sp.sel = i; sp._choose() }
            e.accepted = true
        }
    }
    onAccepted: { if (sp.mode !== 2) sp._choose() }

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

        // Question input (mode 2) — after `a` picked a range.
        Item {
            visible: sp.mode === 2
            width: parent.width; height: 52
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 4; anchors.rightMargin: 4; anchors.topMargin: 4; anchors.bottomMargin: 4
                radius: 13; color: Theme.surface
                border.width: questionInput.activeFocus ? 1.5 : 1
                border.color: questionInput.activeFocus ? Theme.hairline : Theme.hairlineSoft
                TextInput {
                    id: questionInput
                    anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.fg; clip: true; selectByMouse: true
                    font.family: Theme.fontFamily; font.pixelSize: 14
                    onAccepted: sp._submitAsk()
                    Keys.onEscapePressed: ev => { sp.mode = (sp.pendingScope === "user" ? 1 : 0); sp.asking = false; ev.accepted = true }
                    Text {
                        visible: !questionInput.text
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Ask about this conversation…"; color: Theme.fg_muted
                        font: questionInput.font
                    }
                }
            }
        }
    }
}
