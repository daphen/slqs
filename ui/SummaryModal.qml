import QtQuick
import QsLib

// While-away summary, styled after the newtab "Today" card: display hero title,
// mono uppercase section headers with count chips, orange accent on the lead +
// bullet markers. claude returns sectioned markdown (TL;DR, ## HEADERS, - bullets),
// parsed into selectable CATEGORIES: j/k moves the selection, y yanks the
// selected category, Y yanks the whole summary, ⌃d/⌃u scroll a long one.
Modal {
    id: sm
    property string text: ""
    property string meta: "WHILE AWAY"
    property int sel: 0
    panelWidth: Math.round(Math.min(860, sm.width - 64))
    maxHeightFrac: 0.72
    panelColor: Theme.bg

    // the hero TITLE face only — everything else is mono, like the today view
    readonly property var titleFont: ["Sigurd", "Instrument Serif"]
    readonly property string fgHex: "" + Theme.fg
    readonly property var cats: sm._cats(sm.text)

    function showWith(t, ch) {
        text = t || ""
        meta = (ch && ch.length) ? ("" + ch).toUpperCase() : "WHILE AWAY"
        sel = 0
        show()
    }

    function _inline(s) {
        s = (s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        s = s.replace(/\*\*(.+?)\*\*/g, '<span style="color:' + sm.fgHex + ';font-weight:700">$1</span>')
        s = s.replace(/`([^`]+)`/g, '<span style="font-family:' + Theme.fontFamily + '">$1</span>')
        s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
        return s
    }
    function _plain(s) {
        return (s || "").replace(/\*\*(.+?)\*\*/g, "$1").replace(/`([^`]+)`/g, "$1")
                        .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    }

    // Group the markdown into categories (one per ## header; a leading category
    // holds the TL;DR + any pre-header content). Each carries render rows + a
    // plain-text form for yanking.
    function _cats(md) {
        const cats = []
        let cur = null
        const ensure = (title) => { cur = { title: title, rows: [], _p: (title ? [title] : []) }; cats.push(cur) }
        const lines = (md || "").split("\n")
        for (let i = 0; i < lines.length; i++) {
            const ln = lines[i].trim()
            if (!ln) continue
            let m
            if ((m = ln.match(/^#{1,6}\s+(.*)$/))) {
                const t = m[1].replace(/[*:#]+$/, "").toUpperCase()
                ensure(t)
                cur.rows.push({ kind: "head", text: t, count: 0 })
            } else {
                if (!cur) ensure("")
                if ((m = ln.match(/^\*\*TL;?DR:?\*\*\s*(.*)$/i))) { cur.rows.push({ kind: "tldr", html: sm._inline(m[1]) }); cur._p.push(sm._plain(m[1])) }
                else if ((m = ln.match(/^[-*]\s+(.*)$/)))          { cur.rows.push({ kind: "bullet", html: sm._inline(m[1]) }); cur._p.push("• " + sm._plain(m[1])) }
                else                                               { cur.rows.push({ kind: "para", html: sm._inline(ln) }); cur._p.push(sm._plain(ln)) }
            }
        }
        for (let c = 0; c < cats.length; c++) {
            let n = 0
            for (let r = 0; r < cats[c].rows.length; r++) if (cats[c].rows[r].kind === "bullet") n++
            for (let r = 0; r < cats[c].rows.length; r++) if (cats[c].rows[r].kind === "head") cats[c].rows[r].count = n
            cats[c].plain = cats[c]._p.join("\n")
        }
        return cats
    }

    // Keep the selected category in view as j/k move it — reach the Modal's
    // Flickable through the content chain (bodyRoot → Modal's bodyCol → flick).
    onSelChanged: Qt.callLater(sm._reveal)
    function _reveal() {
        if (!open) return
        const item = catRepeater.itemAt(sm.sel)
        const bodyCol = bodyRoot.parent
        const flick = bodyCol ? bodyCol.parent : null
        if (!item || !flick || flick.contentY === undefined) return
        const top = item.mapToItem(bodyCol, 0, 0).y
        const bot = top + item.height
        const pad = 14
        const maxY = Math.max(0, flick.contentHeight - flick.height)
        if (top - pad < flick.contentY) flick.contentY = Math.max(0, top - pad)
        else if (bot + pad > flick.contentY + flick.height) flick.contentY = Math.min(maxY, bot + pad - flick.height)
    }

    onKeyPressed: e => {
        if (e.key === Qt.Key_J || e.key === Qt.Key_Down) { sm.sel = Math.min(sm.sel + 1, sm.cats.length - 1); e.accepted = true }
        else if (e.key === Qt.Key_K || e.key === Qt.Key_Up) { sm.sel = Math.max(sm.sel - 1, 0); e.accepted = true }
        else if (e.key === Qt.Key_Y && (e.modifiers & Qt.ShiftModifier)) {
            const all = sm.cats.map(c => c.plain).join("\n\n")
            Backend.copyRaw(all); Backend.toast("Copied summary"); e.accepted = true
        }
        else if (e.key === Qt.Key_Y) {
            const c = sm.cats[sm.sel]
            if (c) { Backend.copyRaw(c.plain); Backend.toast("Copied " + (c.title ? c.title.toLowerCase() : "summary")) }
            e.accepted = true
        }
    }

    header: Item {
        width: parent.width; height: 40
        Text {
            id: hTitle
            anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.bottomMargin: -2
            text: "Summary"; color: Theme.fg
            font.families: sm.titleFont; font.pixelSize: 34; font.weight: 400; font.capitalization: Font.AllUppercase
            font.letterSpacing: -0.3
        }
        Text {
            anchors.left: hTitle.right; anchors.leftMargin: 12; anchors.baseline: hTitle.baseline
            text: sm.meta; color: Theme.fg_muted
            font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
            font.letterSpacing: 0.6
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.bottom
            anchors.topMargin: 14; height: 1; color: Theme.hairline
        }
    }

    footer: Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 5
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "j/k" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "move" }
        Item { width: 9; height: 1 }
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "y" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "yank" }
        Item { width: 9; height: 1 }
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "Y" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "all" }
        Item { width: 9; height: 1 }
        KeyCap { anchors.verticalCenter: parent.verticalCenter; small: true; text: "esc" }
        CapLabel { anchors.verticalCenter: parent.verticalCenter; text: "close" }
    }

    Column {
        id: bodyRoot
        width: parent.width
        topPadding: 8
        spacing: 6
        Repeater {
            id: catRepeater
            model: sm.cats
            delegate: Item {
                id: cat
                required property int index
                required property var modelData
                width: parent.width
                implicitHeight: catCol.implicitHeight

                // selection highlight behind the whole category — inset 4px so the
                // rounded pill never reaches the Flickable's clip edge (was cut off),
                // and catCol's padding gives the content breathing room inside it.
                Rectangle {
                    anchors.fill: catCol
                    anchors.leftMargin: 4; anchors.rightMargin: 4
                    radius: 12
                    visible: sm.sel === cat.index
                    color: Theme.selection; border.width: 1; border.color: Theme.hairline
                }

                Column {
                    id: catCol
                    width: cat.width
                    leftPadding: 16; rightPadding: 16; topPadding: 8; bottomPadding: 8
                    spacing: 8
                    Repeater {
                        model: cat.modelData.rows
                        delegate: Item {
                            id: row
                            required property var modelData
                            width: catCol.width - catCol.leftPadding - catCol.rightPadding
                            implicitHeight: (tldrL.item ? tldrL.item.implicitHeight : 0)
                                          + (headL.item ? headL.item.implicitHeight : 0)
                                          + (bulletL.item ? bulletL.item.implicitHeight : 0)
                                          + (paraL.item ? paraL.item.implicitHeight : 0)

                            Loader {
                                id: tldrL
                                active: row.modelData.kind === "tldr"; width: parent.width
                                sourceComponent: Text {
                                    width: row.width
                                    text: row.modelData.html; textFormat: Text.RichText; color: Theme.fg
                                    wrapMode: Text.Wrap
                                    font.family: Theme.fontFamily; font.pixelSize: 15; font.weight: 500; lineHeight: 1.5
                                }
                            }
                            Loader {
                                id: headL
                                active: row.modelData.kind === "head"; width: parent.width
                                sourceComponent: Row {
                                    topPadding: 6; bottomPadding: 2; spacing: 8
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: row.modelData.text; color: Theme.fg_muted
                                        font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 600
                                        font.letterSpacing: 1.5
                                    }
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: (row.modelData.count || 0) > 0
                                        height: 16; radius: 8; width: chipT.implicitWidth + 14
                                        color: "transparent"; border.width: 1; border.color: Theme.hairline
                                        Text {
                                            id: chipT; anchors.centerIn: parent
                                            text: row.modelData.count || 0; color: Theme.fg_muted
                                            font.family: Theme.fontFamily; font.pixelSize: 10
                                        }
                                    }
                                }
                            }
                            Loader {
                                id: bulletL
                                active: row.modelData.kind === "bullet"; width: parent.width
                                sourceComponent: Row {
                                    width: row.width; spacing: 10
                                    Text {
                                        text: "▪"; color: Theme.orange; topPadding: 3
                                        font.family: Theme.fontFamily; font.pixelSize: 10
                                    }
                                    Text {
                                        width: row.width - 20
                                        text: row.modelData.html; textFormat: Text.RichText; color: Theme.fg_secondary
                                        wrapMode: Text.Wrap
                                        onLinkActivated: (url) => Backend.openUrl(url)
                                        font.family: Theme.fontFamily; font.pixelSize: 14; lineHeight: 1.45
                                    }
                                }
                            }
                            Loader {
                                id: paraL
                                active: row.modelData.kind === "para"; width: parent.width
                                sourceComponent: Text {
                                    width: row.width
                                    text: row.modelData.html; textFormat: Text.RichText; color: Theme.fg_secondary
                                    wrapMode: Text.Wrap
                                    onLinkActivated: (url) => Backend.openUrl(url)
                                    font.family: Theme.fontFamily; font.pixelSize: 14; lineHeight: 1.45
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
