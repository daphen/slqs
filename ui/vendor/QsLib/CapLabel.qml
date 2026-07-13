// Muted action-ink label that follows a KeyCap in chin rows.
import QtQuick

Text {
    renderType: Text.NativeRendering
    color: Qt.tint(Theme.fg_muted, Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
    font.family: Theme.fontFamily
    font.hintingPreference: Font.PreferNoHinting
    font.pixelSize: 11
}
