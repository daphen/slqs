// The family keycap: raised chip, hairline ring, action-ink glyph.
// Identical recipe across the picker chins, app statusbars, and hint caps.
// `small: true` is the gutter-chip variant (sidebar jump keys); `ghost:
// true` drops the fill for chips sitting on tinted/inverted surfaces.
import QtQuick

Rectangle {
    id: cap
    property alias text: capText.text
    property bool small: false
    property bool ghost: false
    property color textColor: small
        ? Theme.fg_muted
        : Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
    width: small ? Math.max(capText.implicitWidth + 8, 18) : Math.max(capText.implicitWidth + 12, 22)
    height: small ? 18 : 22
    radius: small ? 5 : 7
    color: ghost ? "transparent" : (Theme.mode === "light" ? Theme.bg : Theme.surface2)
    border.width: 1
    border.color: Theme.hairline
    Text {
        id: capText
        renderType: Text.NativeRendering
        anchors.centerIn: parent
        color: cap.textColor
        font.family: Theme.fontFamily
        font.hintingPreference: Font.PreferNoHinting
        font.pixelSize: cap.small ? 10 : 11
        font.weight: 500
    }
}
