pragma Singleton
import QtQuick

// Rich-text HTML helpers. Text.linkColor is silently ignored for
// Text.RichText documents (they fall back to the palette's default blue,
// unreadable in dark mode) — the only reliable way to color links is
// inlining the color into the markup itself.
QtObject {
    function cssHex(c) {
        // degrade instead of throwing: one undefined color must not blank a body
        if (!c || c.r === undefined) return "#888888"
        return "#" + [c.r, c.g, c.b].map(x => Math.round(x * 255).toString(16).padStart(2, "0")).join("")
    }

    function colorLinks(html) {
        if (!html) return ""
        return html.replace(/<a href=/g, '<a style="color:' + cssHex(Theme.sky) + '" href=')
    }
}
