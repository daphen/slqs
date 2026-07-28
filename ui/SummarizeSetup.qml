import QtQuick
import QsLib

// Shown when the summarize button is pressed but no provider is configured.
// Adaptive: it detects which agent CLIs are logged in on THIS machine and offers
// a one-click keyless button per one (no key, runs on the existing plan); and it
// always offers an API-key path where you pick the vendor (Anthropic or OpenAI)
// and paste a key. Both write the summarize block to profiles.json via the daemon.
Modal {
    id: gd
    panelWidth: Math.round(Math.min(600, gd.width - 64))
    maxHeightFrac: 0.75
    panelColor: Theme.bg
    chinBar: true

    readonly property string serif: "Instrument Serif"
    property var clis: Backend.summarizeClis
    property string vendor: "anthropic"     // key-path vendor selection

    // hjkl navigation over the actionable rows: [CLI buttons…, vendor toggle, enable].
    property int sel: 0
    readonly property int nCli: clis.length
    readonly property int vendorRow: nCli
    readonly property int enableRow: nCli + 1
    readonly property int navCount: nCli + 2
    onOpenChanged: if (open) { sel = 0; vendor = "anthropic" }

    function enableCli(id) { Backend.summarizeEnableCli(id); gd.close() }
    function enableKey() {
        const k = keyInput.text.trim()
        if (!k.length) return
        Backend.summarizeEnableKey(gd.vendor, k); gd.close()
    }
    function activate() {
        if (gd.sel < gd.nCli) gd.enableCli(gd.clis[gd.sel].id)
        else if (gd.sel === gd.enableRow) gd.enableKey()
        else keyInput.forceActiveFocus()   // vendor row → drop into the key field
    }
    // hjkl / arrows move the selection; ↵ activates. Inert while the key field
    // has focus (there the letters are text and ↵ submits the field).
    onKeyPressed: e => {
        if (keyInput.activeFocus) return
        if (e.key === Qt.Key_J || e.key === Qt.Key_Down)       { gd.sel = Math.min(gd.sel + 1, gd.navCount - 1); e.accepted = true }
        else if (e.key === Qt.Key_K || e.key === Qt.Key_Up)    { gd.sel = Math.max(gd.sel - 1, 0); e.accepted = true }
        else if (e.key === Qt.Key_L || e.key === Qt.Key_Right) { if (gd.sel === gd.vendorRow) gd.vendor = "openai"; else gd.sel = Math.min(gd.sel + 1, gd.navCount - 1); e.accepted = true }
        else if (e.key === Qt.Key_H || e.key === Qt.Key_Left)  { if (gd.sel === gd.vendorRow) gd.vendor = "anthropic"; else gd.sel = Math.max(gd.sel - 1, 0); e.accepted = true }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { gd.activate(); e.accepted = true }
    }

    header: Item {
        width: parent.width; height: 40
        Text {
            id: t
            anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.bottomMargin: -2
            text: "Set up summaries"; color: Theme.fg
            font.family: gd.serif; font.pixelSize: 30; font.weight: 400
            font.letterSpacing: -0.3
        }
        Text {
            anchors.left: t.right; anchors.leftMargin: 12; anchors.baseline: t.baseline
            text: "CHOOSE A PROVIDER"; color: Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
            font.letterSpacing: 0.6
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.bottom
            anchors.topMargin: 14; height: 1; color: Theme.hairline
        }
    }

    footer: Item {
        width: parent.width; height: 42
        Row {
            anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 5
            KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "esc" }
            CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "close" }
        }
    }

    Column {
        width: parent.width
        topPadding: 6
        spacing: 16

        Text {
            width: parent.width
            text: "Summaries run through a model provider you pick — nothing is set up yet."
            color: Theme.fg_secondary; wrapMode: Text.Wrap
            font.family: Theme.fontFamily; font.pixelSize: 14; lineHeight: 1.45
        }

        // ── Keyless: one button per logged-in agent CLI found on this machine ──
        Column {
            width: parent.width; spacing: 8
            visible: gd.clis.length > 0
            Text {
                text: "USE A LOGGED-IN AGENT"; color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 600; font.letterSpacing: 1.2
            }
            Repeater {
                model: gd.clis
                Rectangle {
                    required property var modelData
                    required property int index
                    width: parent.width; height: 42; radius: Theme.radiusSm
                    color: gd.sel === index ? Theme.selection : (kHov.hovered ? Theme.hover : Theme.surface)
                    border.width: gd.sel === index ? 2 : 1
                    border.color: gd.sel === index ? Theme.fg_secondary : Theme.hairline
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Row {
                        anchors.centerIn: parent; spacing: 8
                        Icon { name: "sparkle-3"; width: 14; height: 14; anchors.verticalCenter: parent.verticalCenter; color: Theme.fg_secondary }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Enable with " + modelData.label; color: Theme.fg
                            font.family: Theme.fontFamily; font.pixelSize: 14; font.weight: 600
                        }
                    }
                    HoverHandler { id: kHov }
                    TapHandler { onTapped: gd.enableCli(modelData.id) }
                }
            }
            Text {
                width: parent.width
                text: "No API key — runs on your existing plan, using the CLI already logged in here."
                color: Theme.fg_muted; wrapMode: Text.Wrap
                font.family: Theme.fontFamily; font.pixelSize: 12; lineHeight: 1.4
            }
        }

        // ── API key: pick the vendor, paste a key ─────────────────────────────
        Column {
            width: parent.width; spacing: 8
            Text {
                text: "USE AN API KEY"; color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 600; font.letterSpacing: 1.2
            }
            // vendor toggle
            Row {
                width: parent.width; spacing: 8
                Repeater {
                    model: [{ id: "anthropic", label: "Anthropic" }, { id: "openai", label: "OpenAI" }]
                    Rectangle {
                        required property var modelData
                        readonly property bool on: gd.vendor === modelData.id
                        readonly property bool cellSel: gd.sel === gd.vendorRow && on
                        width: (parent.width - 8) / 2; height: 38; radius: Theme.radiusSm
                        color: cellSel ? Theme.selection : (on ? Theme.surface : (vHov.hovered ? Theme.hover : "transparent"))
                        border.width: cellSel ? 2 : 1
                        border.color: cellSel ? Theme.fg_secondary : (on ? Theme.hairline : Theme.hairlineSoft)
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text {
                            anchors.centerIn: parent; text: modelData.label
                            color: parent.on ? Theme.fg : Theme.fg_muted
                            font.family: Theme.fontFamily; font.pixelSize: 14; font.weight: 600
                        }
                        HoverHandler { id: vHov }
                        TapHandler { onTapped: gd.vendor = modelData.id }
                    }
                }
            }
            Rectangle {
                width: parent.width; height: 42; radius: Theme.radiusSm
                color: Theme.surface
                border.width: keyInput.activeFocus ? 1.5 : 1
                border.color: Theme.hairline
                TextInput {
                    id: keyInput
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.fg; clip: true; selectByMouse: true; echoMode: TextInput.Password
                    font.family: Theme.fontFamily; font.pixelSize: 14
                    onAccepted: gd.enableKey()
                    Keys.onEscapePressed: { keyInput.focus = false; gd.sel = gd.enableRow }
                    Text { visible: !keyInput.text; anchors.verticalCenter: parent.verticalCenter
                           text: (gd.vendor === "anthropic" ? "sk-ant-…" : "sk-…") + "  (paste your API key)"
                           color: Theme.fg_muted; font: keyInput.font }
                }
            }
            Rectangle {
                width: parent.width; height: 42; radius: Theme.radiusSm
                readonly property bool on: keyInput.text.trim().length > 0
                readonly property bool navSel: gd.sel === gd.enableRow
                color: !on ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04)
                     : (navSel || eHov.hovered) ? Theme.selection : Theme.surface
                border.width: navSel ? 2 : 1; border.color: navSel ? Theme.fg_secondary : (on ? Theme.hairline : Theme.hairlineSoft)
                Behavior on color { ColorAnimation { duration: 100 } }
                Text { anchors.centerIn: parent
                       text: "Enable with " + (gd.vendor === "anthropic" ? "Anthropic" : "OpenAI")
                       color: parent.on ? Theme.fg : Theme.fg_muted
                       font.family: Theme.fontFamily; font.pixelSize: 14; font.weight: 600 }
                HoverHandler { id: eHov }
                TapHandler { enabled: parent.on; onTapped: gd.enableKey() }
            }
            Text {
                width: parent.width
                text: "A small, fast model is used (" + (gd.vendor === "anthropic" ? "Haiku" : "gpt-4o-mini") + "). The key is stored in profiles.json; change the model there later."
                color: Theme.fg_muted; wrapMode: Text.Wrap
                font.family: Theme.fontFamily; font.pixelSize: 12; lineHeight: 1.4
            }
        }

        Text {
            width: parent.width
            text: "Other providers (local Ollama, etc.): add a summarize block to ~/.config/dsqrd/profiles.json."
            color: Theme.fg_muted; wrapMode: Text.Wrap
            font.family: Theme.fontFamily; font.pixelSize: 12; lineHeight: 1.4
        }
    }
}
