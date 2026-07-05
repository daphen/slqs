// AUTO-GENERATED — edit the template, not this file.
// Driver: themes/.config/themes/theme-processor.py
// Theme for the native QML Slack/Discord client (~/personal/slk-gui-proto).
// Both palettes are inlined; the active one is selected at runtime by watching
// ~/.config/theme_mode, so light/dark toggles reflow the client without a
// restart (same mechanism as the quickshell bar Theme).
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: theme

    property string mode: "dark"

    readonly property var palettes: ({
        "light": {
            "bg":          "#FAF9F6",
            "bg_alt":      "#F2F1EE",
            "selection":   "#E7E5E1",
            "surface":     "#EDECE9",
            "overlay":     "#E0DFDC",
            "prompt":      "#E8EAED",
            "fg":          "#2D4A3D",
            "fg_secondary":"#575279",
            "fg_muted":    "#6B6E7A",
            "red":         "#7c3438",
            "orange":      "#e16511",
            "yellow":      "#df9001",
            "green":       "#5E7270",
            "sky":         "#0284C7",
            "cursor":      "#FF570D",
            "ink":         "#1C1C1C",
            "warning":     "#F5DECE",
            "brightWhite": "#D5D1C5",
            "hairlineAlpha": 0.5,
            "dimmedFgAlpha": 0.55
        },
        "dark": {
            "bg":          "#181818",
            "bg_alt":      "#1B1B1B",
            "selection":   "#2E2E2E",
            "surface":     "#1B1B1B",
            "overlay":     "#292826",
            "prompt":      "#323A40",
            "fg":          "#EDEDED",
            "fg_secondary":"#C3C8C6",
            "fg_muted":    "#707B84",
            "red":         "#FF7B72",
            "orange":      "#FF570D",
            "yellow":      "#ff8a31",
            "green":       "#97B5A6",
            "sky":         "#7DD3FC",
            "cursor":      "#FF570D",
            "ink":         "#1B1B1B",
            "warning":     "#462415",
            "brightWhite": "#D5DAD8",
            "hairlineAlpha": 0.15,
            "dimmedFgAlpha": 0.7
        }
    })

    readonly property color bg:           palettes[mode].bg
    readonly property color bg_alt:       palettes[mode].bg_alt
    readonly property color selection:    palettes[mode].selection
    readonly property color surface:      palettes[mode].surface
    readonly property color overlay:      palettes[mode].overlay
    readonly property color prompt:       palettes[mode].prompt
    readonly property color fg:           palettes[mode].fg
    readonly property color fg_secondary: palettes[mode].fg_secondary
    readonly property color fg_muted:     palettes[mode].fg_muted
    readonly property color red:          palettes[mode].red
    readonly property color orange:       palettes[mode].orange
    readonly property color yellow:       palettes[mode].yellow
    readonly property color green:        palettes[mode].green
    readonly property color sky:          palettes[mode].sky
    readonly property color cursor:       palettes[mode].cursor
    // Exposed existing palette colors (no new colors.json entries): near-black for
    // text on bright accents/badges + the modal scrim, the warning bg + yellow for
    // the self-mention highlight, and a near-white for text on dark accent chips.
    readonly property color ink:          palettes[mode].ink
    readonly property color warning:      palettes[mode].warning
    readonly property color brightWhite:  palettes[mode].brightWhite

    readonly property real hairlineAlpha: palettes[mode].hairlineAlpha
    readonly property real dimmedFgAlpha: palettes[mode].dimmedFgAlpha
    readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, hairlineAlpha)
    readonly property color dimmedFg: Qt.rgba(fg.r, fg.g, fg.b, dimmedFgAlpha)
    // Hover/selection tint derived from fg, so it shows in light mode (the old
    // hardcoded white-alpha overlays were invisible on light backgrounds).
    readonly property color hover:    Qt.rgba(fg.r, fg.g, fg.b, 0.06)

    readonly property int radius:    12
    readonly property int radiusSm:  7
    readonly property int padding:   12
    readonly property int paddingSm: 6
    readonly property int fontSize:  14
    readonly property string fontFamily: "JetBrainsMono Nerd Font"
    readonly property int fontWeight: 500

    readonly property var avatarColors: [
        "#FF570D", "#97B5A6", "#7DD3FC", "#8A92A7",
        "#ff8a31", "#CCD5E4", "#FF7B72", "#8A9AA6"
    ]

    // Follow the system light/dark toggle (same file the bar watches).
    FileView {
        id: themeFile
        path: Quickshell.env("HOME") + "/.config/theme_mode"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const v = (text() || "").trim()
            if (v === "light" || v === "dark") theme.mode = v
        }
    }
}
