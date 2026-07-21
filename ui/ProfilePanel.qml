import QtQuick
import Quickshell.Widgets
import "."
import QsLib

// Right-hand profile card (slqs): the focused message author's users.info
// card, fetched live by the daemon. Opened with P, closed with q/esc, M DMs
// them. Same slide-in card grammar as ThreadPanel.
Rectangle {
    id: panel
    color: Theme.bg
    radius: Theme.radiusCard

    readonly property var p: Backend.profileData
    readonly property string uid: Backend.profileUser
    readonly property string presence: Backend.presenceOf(Backend.currentWorkspace, uid)

    // Hairpin outline drawn above the content, like the thread panel.
    Rectangle {
        anchors.fill: parent; z: 999
        color: "transparent"
        radius: Theme.radiusCard
        border.width: 1
        border.color: Theme.hairlineSoft
    }

    // their local clock, ticking while the panel is open
    property var now: new Date()
    Timer {
        interval: 30000; repeat: true; triggeredOnStart: true
        running: Backend.profileOpen
        onTriggered: panel.now = new Date()
    }
    function localTime() {
        if (p.tzOffset === undefined || p.tzOffset === null || !p.tz) return ""
        const utc = now.getTime() + now.getTimezoneOffset() * 60000
        return Qt.formatTime(new Date(utc + p.tzOffset * 1000), "hh:mm") + "  ·  " + p.tz
    }

    component Detail: Column {
        property string label: ""
        property string value: ""
        property bool wrap: false
        visible: value !== ""
        width: parent.width
        spacing: 3
        topPadding: 14
        Text {
            renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
            text: parent.label
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: 11; font.letterSpacing: 1.2
            font.capitalization: Font.AllUppercase
        }
        Text {
            renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
            width: parent.width
            text: parent.value
            color: Theme.fg
            elide: parent.wrap ? Text.ElideNone : Text.ElideRight
            wrapMode: parent.wrap ? Text.Wrap : Text.NoWrap
            font.family: Theme.fontFamily; font.pixelSize: 13
        }
    }

    Column {
        anchors.fill: parent
        anchors.margins: Theme.insetCard + 10
        spacing: 0

        ClippingRectangle {
            id: bannerClip
            visible: (panel.p.banner || "") !== ""
            width: parent.width
            height: visible ? 92 : 0
            radius: 16
            color: Theme.surface
            Image {
                anchors.fill: parent
                source: panel.p.banner || ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: 900
            }
        }
        Item { width: 1; height: bannerClip.visible ? 14 : 0 }

        ClippingRectangle {
            id: avatarClip
            width: 96; height: 96; radius: 24
            color: Theme.surface
            Image {
                anchors.fill: parent
                source: panel.p.avatar || ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: 192; sourceSize.height: 192
            }
        }

        Item { width: 1; height: 16 }

        Row {
            spacing: 8
            Text {
                renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                text: panel.p.name || ""
                color: Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: 19; font.weight: 600
            }
            // presence dot: green online · yellow idle · red dnd · hollow offline.
            // Prefer the daemon's fine-grained status (Discord), else the coarse
            // active/away the sidebar uses (Slack).
            Rectangle {
                width: 9; height: 9; radius: 4.5
                anchors.verticalCenter: parent.verticalCenter
                readonly property string st: panel.p.presence || (panel.presence === "active" ? "online" : "")
                readonly property bool filled: st === "online" || st === "idle" || st === "dnd"
                color: st === "online" ? Theme.green : st === "idle" ? Theme.yellow
                     : st === "dnd" ? Theme.red : "transparent"
                border.width: filled ? 0 : 1
                border.color: Theme.fg_muted
            }
            StatusEmoji {
                px: 16
                anchors.verticalCenter: parent.verticalCenter
                emoji: Backend.statusOf(Backend.currentWorkspace, panel.uid) || (panel.p.statusEmoji || "")
            }
        }

        Item { width: 1; height: 4 }

        Text {
            renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
            text: {
                const bits = []
                if (panel.p.realName && panel.p.realName !== panel.p.name) bits.push(panel.p.realName)
                if (panel.p.handle) bits.push("@" + panel.p.handle)
                if (panel.p.pronouns) bits.push(panel.p.pronouns)
                if (panel.p.isBot) bits.push("bot")
                return bits.join("  ·  ")
            }
            visible: text !== ""
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: 12
        }

        Text {
            renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
            visible: (panel.p.activity || "") !== ""
            width: parent.width
            topPadding: 8
            text: panel.p.activity || ""
            color: Theme.green
            wrapMode: Text.Wrap
            font.family: Theme.fontFamily; font.pixelSize: 12
        }

        Text {
            renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
            visible: (panel.p.statusText || "") !== ""
            width: parent.width
            topPadding: 10
            text: panel.p.statusText || ""
            color: Theme.fg_secondary
            wrapMode: Text.Wrap
            font.family: Theme.fontFamily; font.pixelSize: 13
        }

        Item { width: 1; height: 18 }
        Rectangle { width: parent.width; height: 1; color: Theme.hairline }

        Detail { label: "About";       value: panel.p.bio || ""; wrap: true }
        Detail { label: "Connections"; value: panel.p.connections || ""; wrap: true }
        Detail { label: "On Discord since"; value: panel.p.created || "" }
        Detail { label: "Title";      value: panel.p.title || "" }
        Detail { label: "Local time"; value: panel.localTime() }
        Detail { label: "Email";      value: panel.p.email || "" }
        Detail { label: "Phone";      value: panel.p.phone || "" }
    }
}
