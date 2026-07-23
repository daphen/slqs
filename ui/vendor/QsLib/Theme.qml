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
            "bg":          "#FFFFFF",
            "bg_alt":      "#F6F7F4",
            "selection":   "#F4F5F2",
            "surface":     "#F7F7F7",
            "surface0":    "#FBFBFB",
            "surface1":    "#F7F7F7",
            "surface2":    "#EDEDED",
            "surface3":    "#E4E4E4",
            "overlay":     "#E9EAE7",
            "prompt":      "#EEEFEC",
            "fg":          "#10100E",
            "fg_secondary":"#3C3C3A",
            "fg_muted":    "#959693",
            "red":         "#7c3438",
            "orange":      "#e16511",
            "yellow":      "#df9001",
            "green":       "#5E7270",
            "sky":         "#0284C7",
            "cursor":      "#FF570D",
            "ink":         "#1C1C1C",
            "warning":     "#F5DECE",
            "brightWhite": "#D5D1C5",
            "hairlineAlpha": 0.12,
            "dimmedFgAlpha": 0.55
        },
        "dark": {
            "bg":          "#181818",
            "bg_alt":      "#1B1B1B",
            "selection":   "#2E2E2E",
            "surface":     "#1B1B1B",
            "surface0":    "#1A1A1A",
            "surface1":    "#1B1B1B",
            "surface2":    "#2E2E2E",
            "surface3":    "#3A3A3A",
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
    // elevation ladder (derived by theme-processor): 1 texture, 2 structure, 3 engaged
    readonly property color surface0:     palettes[mode].surface0
    readonly property color surface1:     palettes[mode].surface1
    readonly property color surface2:     palettes[mode].surface2
    readonly property color surface3:     palettes[mode].surface3
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
    // softer hairpin for low-emphasis outlines (unread pills, quiet chips)
    readonly property color hairlineSoft: Qt.rgba(fg.r, fg.g, fg.b, hairlineAlpha * 0.6)
    readonly property color dimmedFg: Qt.rgba(fg.r, fg.g, fg.b, dimmedFgAlpha)
    // Hover/selection tint derived from fg, so it shows in light mode (the old
    // hardcoded white-alpha overlays were invisible on light backgrounds).
    readonly property color hover:    Qt.rgba(fg.r, fg.g, fg.b, 0.06)

    readonly property int radius:    12
    readonly property int radiusSm:  7
    // picker-grammar card geometry: floating surfaces sit at radiusCard,
    // nested boxes inset by insetCard and use radiusInner (outer − inset)
    readonly property int radiusCard: 24
    readonly property int insetCard:  14
    readonly property int radiusInner: radiusCard - insetCard
    readonly property int padding:   12
    readonly property int paddingSm: 6
    readonly property int fontSize:  14
    readonly property string fontFamily: "GeistMono Nerd Font"
    // 400 under NativeRendering ≈ the old 500 under distance fields
    readonly property int fontWeight: 400

    // Insert-mode composer fill + mention-of-you background.
    readonly property color tintFill: surface2

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
