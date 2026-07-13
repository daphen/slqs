import QtQuick
import Quickshell.Widgets
import "."
import QsLib

Item {
    id: del
    required property string author
    required property string initials
    required property string color
    required property string time
    required property string text
    required property bool   grouped
    required property string reactionsJson
    required property int    reply_count
    required property string avatar
    required property string imagesJson
    required property string replyAuthor
    required property string replyText
    required property string subtype
    required property bool   edited
    property bool inThread: false   // true when rendered in the thread panel
    required property int    index
    required property bool   pending
    required property string day
    required property string ts
    readonly property bool isReply: replyAuthor.length > 0 || replyText.length > 0
    // Per-row date divider: shown when this is the first message of its day (channel
    // only). Replaces the ListView section, which mis-dated rows after image reflows.
    readonly property string _prevDay: (ListView.view && index > 0) ? (ListView.view.model.get(index - 1).day || "") : ""
    readonly property bool showDay: !inThread && (index === 0 || day !== _prevDay)
    readonly property real _dayPad: showDay ? 34 : 0
    width: ListView.view ? ListView.view.width : 600
    // extra height must match body's top margin so top/bottom padding stay even
    // (a grouped message with a reply line uses the larger 7px top margin).
    implicitHeight: _dayPad + body.implicitHeight + ((grouped && !isReply) ? 6 : 14)
    // pending optimistic send: lighter until the server echo lands, then fade in
    opacity: pending ? 0.5 : 1.0
    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

    readonly property var reactions: JSON.parse(reactionsJson)
    readonly property var images: (imagesJson && imagesJson.length) ? JSON.parse(imagesJson) : []
    readonly property bool cursor: ListView.isCurrentItem && ListView.view && ListView.view.active
    readonly property bool emojiOnly: Backend.isEmojiOnly(text)

    // date divider, rendered as part of this row (the first message of a day)
    Item {
        id: dayDiv
        visible: del.showDay
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: del._dayPad
        Rectangle { anchors.verticalCenter: parent.verticalCenter; x: 20; width: parent.width - 40
                    height: 1; color: Theme.hairline }
        Rectangle {
            anchors.centerIn: parent; height: 20; radius: 10
            width: dayLbl.implicitWidth + 22
            color: Theme.bg; border.color: Theme.hairline; border.width: 1
            Text { id: dayLbl; anchors.centerIn: parent; renderType: Text.NativeRendering
                   text: Backend.dayLabel(del.day); color: Theme.fg_muted
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12; font.weight: 500 }
        }
    }

    Rectangle {
        anchors { top: parent.top; topMargin: del._dayPad; left: parent.left; right: parent.right; bottom: parent.bottom }
        anchors.leftMargin: 14; anchors.rightMargin: 14
        radius: Theme.radiusSm
        // No color/opacity animation here: the cursor must snap instantly so fast
        // j/k navigation doesn't catch rows mid-fade (reads as blinking).
        color: del.cursor ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.6)
             : hov.hovered ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.5) : "transparent"
        // mail-index cursor grammar: strong fg-alpha hairpin so the cursor
        // reads even where the selection tint sinks into the card
        border.width: del.cursor ? 1 : 0
        border.color: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.35)
    }

    // Brief accent pulse when this row is jumped to via a permalink.
    Rectangle {
        anchors { top: parent.top; topMargin: del._dayPad; left: parent.left; right: parent.right; bottom: parent.bottom }
        color: Theme.sky
        opacity: (del.ListView.view && del.ListView.view.flashIndex === del.index) ? 0.28 : 0
        Behavior on opacity { NumberAnimation { duration: 320 } }
    }

    // Green row highlight, driven by the SAME state + easing as the cursor-bar
    // morph (cursorMark.showCopy, 250ms InOutQuad) so the two animate in exact
    // sync — fade in, hold, and fade out as one motion.
    Rectangle {
        id: copyFlash
        anchors { top: parent.top; topMargin: del._dayPad; left: parent.left; right: parent.right; bottom: parent.bottom }
        color: Qt.darker(Theme.selection, 1.03)   // copy = a touch darker than the full highlight
        opacity: cursorMark.showCopy ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
    }


    // vim relative line numbers (only while this list is the focused panel):
    // an orange bar (matching the sidebar's current-channel marker) marks the
    // cursor row, the others show distance-from-cursor — so "8j"/"3k" jumps are
    // countable without a giant absolute line number.
    Item {
        visible: del.ListView.view && del.ListView.view.showNumbers
        anchors.left: parent.left; anchors.right: gutter.left
        // Center on the avatar (pfp) for a leading message; for a grouped message
        // (no avatar) center on its single text line instead.
        anchors.top: parent.top
        anchors.topMargin: (del.grouped ? 3 : 9) + del._dayPad
        height: del.grouped ? 20 : 36
        // Cursor marker that briefly morphs into a copy icon when this row is
        // copied — transitions.dev icon-swap (250ms ease-in-out, scale 0.25).
        Item {
            id: cursorMark
            visible: del.cursor; anchors.centerIn: parent
            width: 16; height: 16
            property bool showCopy: false
            Connections {
                target: Backend
                function onCopiedTsChanged() {
                    if (del.ts.length > 0 && Backend.copiedTs === del.ts) { cursorMark.showCopy = true; copyRevert.restart() }
                }
            }
            Timer { id: copyRevert; interval: 1500; onTriggered: cursorMark.showCopy = false }
            Rectangle {   // the bar (resting state)
                anchors.centerIn: parent
                width: 3; height: 16; radius: 2; color: Theme.cursor
                opacity: cursorMark.showCopy ? 0 : 1
                scale: cursorMark.showCopy ? 0.25 : 1
                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
            }
            Text {   // the copy icon (nf-fa-copy)
                // QtRendering on purpose: this glyph scale-animates, and native
                // glyphs don't survive transforms. Everything static is Native.
                renderType: Text.QtRendering; renderTypeQuality: Text.VeryHighRenderTypeQuality
                anchors.centerIn: parent
                text: ""; color: Theme.cursor
                font.family: Theme.fontFamily; font.pixelSize: 16
                opacity: cursorMark.showCopy ? 1 : 0
                scale: cursorMark.showCopy ? 1 : 0.25
                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
            }
        }
        Text { renderType: Text.NativeRendering
            visible: !del.cursor
            anchors.right: parent.right; anchors.rightMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: Math.abs(del.index - del.ListView.view.currentIndex)
            color: Theme.fg_secondary
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 11; font.weight: 500
        }
    }

    // gutter: avatar (first in group) or hover-timestamp (continuation)
    Item {
        id: gutter
        x: 34; width: 40
        anchors.top: parent.top; anchors.topMargin: (del.grouped ? 3 : 9) + del._dayPad
        height: 40
        // Text OUTSIDE the clip: ClippingRectangle rasterizes children at
        // 1x DPR, blurring glyphs on a fractional-scale monitor.
        Rectangle {
            visible: !del.grouped
            width: 36; height: 36; radius: 8
            color: del.color                    // colored fallback behind the image

            Text { renderType: Text.NativeRendering;
                anchors.centerIn: parent; text: del.initials; color: Theme.ink
                visible: avatarImg.status !== Image.Ready
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 14; font.weight: 500
            }
            ClippingRectangle {
                anchors.fill: parent; radius: parent.radius; color: "transparent"
                Image {
                    id: avatarImg
                    anchors.fill: parent
                    source: del.avatar           // straight from the model row
                    visible: status === Image.Ready
                    asynchronous: true; cache: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 96; sourceSize.height: 96
                }
            }
        }
        Text { renderType: Text.NativeRendering;
            visible: del.grouped && hov.hovered
            anchors.horizontalCenter: parent.horizontalCenter; y: 1
            text: del.time; color: Theme.fg_muted; font.features: ({ "tnum": 1 })
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 11
        }
    }

    Column {
        id: body
        anchors.left: gutter.right; anchors.leftMargin: 10
        anchors.right: parent.right; anchors.rightMargin: 18
        anchors.top: parent.top; anchors.topMargin: (del.grouped && !del.isReply ? 3 : 7) + del._dayPad
        spacing: 3

        // reply context (Discord): "↰ author  quoted snippet" above the message
        Row {
            visible: del.isReply
            width: parent.width
            spacing: 5
            Text { renderType: Text.NativeRendering; text: "↰"; color: Theme.fg_muted
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13 }
            Text { renderType: Text.NativeRendering; text: del.replyAuthor; color: Theme.sky
                   visible: del.replyAuthor.length > 0
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13; font.weight: 500 }
            Text { renderType: Text.NativeRendering; text: del.replyText; color: Theme.fg_muted
                   width: Math.max(0, body.width - 140); elide: Text.ElideRight
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13 }
        }

        Row {
            visible: !del.grouped
            spacing: 8
            Text { renderType: Text.NativeRendering; text: del.author; color: Theme.mode === "light" ? Theme.ink : Theme.fg
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15; font.weight: 500 }
            Text { renderType: Text.NativeRendering; text: del.time + (del.edited ? "  (edited)" : ""); color: Theme.fg_muted; font.features: ({ "tnum": 1 }); anchors.bottom: parent.bottom; anchors.bottomMargin: 1
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12 }
        }

        Text { renderType: Text.NativeRendering;
            visible: del.text.length > 0 && !del.emojiOnly
            width: parent.width
            // grouped rows have no visible header, so the marker rides the body there
            text: Backend.richify(del.text, 22)
                  + (del.edited && del.grouped ? " <span style='font-size:11px;color:" + Theme.fg_muted + "'>(edited)</span>" : "")
            // Light mode: plain black body text (the theme's secondary fg is a
            // purple that reads wrong for message content). Dark mode: fg (#EDEDED),
            // the same near-white neovim's Normal text uses.
            color: Theme.mode === "light" ? Theme.ink : Theme.fg
            textFormat: Text.RichText
            wrapMode: Text.Wrap
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 15
            onLinkActivated: (link) => Backend.openUrl(link)
        }

        // Emoji-only messages render large, and as real Image elements so custom
        // emoji antialias when scaled (inline rich-text <img> does not). AnimatedImage
        // also animates gif/animated custom emoji.
        Flow {
            visible: del.emojiOnly && del.text.length > 0
            width: parent.width; spacing: 4
            Repeater {
                model: del.emojiOnly ? Backend.emojiParts(del.text) : []
                delegate: Item {
                    id: part
                    required property var modelData
                    width: part.modelData.img ? 40 : glyphT.implicitWidth
                    height: 40
                    AnimatedImage {
                        visible: !!part.modelData.img
                        source: part.modelData.img || ""
                        anchors.verticalCenter: parent.verticalCenter
                        width: 40; height: 40; fillMode: Image.PreserveAspectFit
                        smooth: true; mipmap: true; cache: true
                        sourceSize.width: 128; sourceSize.height: 128
                    }
                    Text {
                        id: glyphT
                        visible: !part.modelData.img
                        text: part.modelData.glyph || ""
                        anchors.verticalCenter: parent.verticalCenter
                        renderType: Text.NativeRendering
                        color: Theme.mode === "light" ? Theme.ink : Theme.fg
                        font.family: "Noto Color Emoji"; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 36
                    }
                }
            }
        }

        // image attachments (thumbnails, downloaded locally by export/slkd)
        Column {
            spacing: 4; topPadding: del.images.length > 0 ? 2 : 0
            Repeater {
                model: del.images
                delegate: ClippingRectangle {
                    // index into del.images directly — a `modelData` here would
                    // collide with the message's modelData from the ListView.
                    required property int index
                    readonly property var img: del.images[index]
                    radius: Theme.radiusSm
                    color: Theme.surface
                    // cap to a sane inline size, preserve aspect ratio
                    readonly property real maxW: Math.min(380, del.width - 80)
                    // videos render as a compact 16:9 card — the poster fills it if
                    // one loads, otherwise it's a plain ▶ card (never a big empty box).
                    readonly property bool isVideo: img.type === "video"
                    // documents render as a compact chip, not an image frame
                    readonly property bool isFile: img.type === "file"
                    readonly property real ar: isVideo ? 0.5625 : ((img.w > 0 && img.h > 0) ? img.h / img.w : 0.66)
                    width: isFile ? Math.ceil(fileRow.implicitWidth) + 24 : (isVideo ? Math.min(320, maxW) : Math.min(maxW, img.w || maxW))
                    height: isFile ? 32 : width * ar
                    border.width: isFile ? 1 : 0
                    border.color: Theme.hairlineSoft

                    Row {
                        id: fileRow
                        visible: parent.isFile
                        // integer anchoring: centerIn lands text on half-pixels
                        // and NativeRendering goes soft
                        anchors.left: parent.left; anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7
                        Icon {
                            name: "paperclip"; width: 13; height: 13
                            color: Theme.fg_secondary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            renderType: Text.NativeRendering
                            anchors.verticalCenter: parent.verticalCenter
                            text: img.name || "file"
                            color: Theme.fg
                            font.family: Theme.fontFamily; font.pixelSize: 12; font.weight: 500
                        }
                        Text {
                            renderType: Text.NativeRendering
                            anchors.verticalCenter: parent.verticalCenter
                            text: (img.ext || "").toUpperCase()
                                  + (img.size ? "  ·  " + (img.size > 1048576
                                      ? (img.size/1048576).toFixed(1) + " MB"
                                      : Math.max(1, Math.round(img.size/1024)) + " KB") : "")
                            color: Theme.fg_muted
                            font.family: Theme.fontFamily; font.pixelSize: 11
                        }
                    }
                    HoverHandler { enabled: parent ? parent.isFile : false; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        enabled: parent.isFile
                        onTapped: if (img.link) Qt.openUrlExternally(img.link)
                    }
                    // gifs animate inline (AnimatedImage); stills use Image.
                    // Only the matching element loads its source.
                    Image {
                        id: still
                        anchors.fill: parent
                        visible: img.type !== "gif"
                        source: img.type !== "gif" ? (img.path || "") : ""
                        fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: true
                        sourceSize.width: 760   // HiDPI-crisp at the inline cap
                        // a load raced against the daemon's download fails once and
                        // Qt never retries on its own — nudge it until the file lands
                        property int retries: 0
                        onStatusChanged: if (status === Image.Error && retries < 6) stillRetry.restart()
                        Timer {
                            id: stillRetry; interval: 700
                            onTriggered: {
                                still.retries++
                                const s = still.source
                                still.source = ""
                                still.source = s
                            }
                        }
                    }
                    AnimatedImage {
                        anchors.fill: parent
                        visible: img.type === "gif"
                        source: img.type === "gif" ? (img.path || "") : ""
                        fillMode: Image.PreserveAspectCrop; cache: true
                        playing: visible; speed: 1.0
                    }
                    // video: still poster (via the Image above) with a play badge.
                    // Press `v` on the message to download + play it in mpv.
                    Rectangle {
                        visible: img.type === "video"
                        anchors.centerIn: parent
                        width: 52; height: 52; radius: 26
                        color: Qt.rgba(0, 0, 0, 0.5)
                        border.color: Qt.rgba(1, 1, 1, 0.85); border.width: 2
                        Text { renderType: Text.NativeRendering
                               anchors.centerIn: parent; anchors.horizontalCenterOffset: 2
                               text: "▶"; color: "white"; font.pixelSize: 22 }
                    }
                }
            }
        }

        // reaction pills
        Flow {
            visible: del.reactions.length > 0
            width: parent.width; spacing: 5; topPadding: 2
            Repeater {
                model: del.reactions
                delegate: Rectangle {
                    required property var modelData
                    height: 22; width: pill.implicitWidth + 16; radius: 11
                    // highlight reactions you've added (mine) with the accent
                    color: modelData.mine ? Qt.rgba(Theme.sky.r, Theme.sky.g, Theme.sky.b, 0.18)
                                           : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.06)
                    border.color: modelData.mine ? Theme.sky : Theme.hairline; border.width: 1
                    Row {
                        id: pill; anchors.centerIn: parent; spacing: 4
                        // custom emoji (:name:) → image; standard (unicode) → glyph
                        property string _name: /^:[a-z0-9_+'\-]+:$/.test(modelData.e) ? modelData.e.slice(1, -1) : ""
                        // Discord custom reaction → CDN img on the reaction itself;
                        // else Slack :name: custom emoji from the merged map.
                        property string _path: { const _ = Backend.emojiGen; return modelData.img ? modelData.img : (pill._name && Backend._emoji[pill._name] ? Backend._emoji[pill._name] : "") }
                        Image {
                            visible: pill._path !== ""
                            width: 18; height: 18; anchors.verticalCenter: parent.verticalCenter
                            source: pill._path; fillMode: Image.PreserveAspectFit
                            sourceSize.width: 36; sourceSize.height: 36
                        }
                        Text { renderType: Text.NativeRendering; visible: pill._path === ""; text: modelData.e; font.pixelSize: 17
                               anchors.verticalCenter: parent.verticalCenter }
                        Text { renderType: Text.NativeRendering; text: modelData.n; color: Theme.fg_muted
                               anchors.verticalCenter: parent.verticalCenter
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12; font.weight: 500 }
                    }
                }
            }
        }

        // broadcast — a thread reply also sent to the channel. In the channel it
        // reads "replied to a thread"; in the thread it reads "also sent to channel".
        Text { renderType: Text.NativeRendering;
            visible: del.subtype === "thread_broadcast"
            topPadding: 3
            text: del.inThread ? "↪ also sent to channel" : "↪ replied to a thread"
            color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 12; font.italic: true
        }
        // thread indicator — Enter opens it
        Text { renderType: Text.NativeRendering;
            visible: del.reply_count > 0
            topPadding: 3
            text: "  " + del.reply_count + (del.reply_count === 1 ? " reply" : " replies")
            color: Theme.sky
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting; font.pixelSize: 13; font.weight: 500
        }
    }

    HoverHandler { id: hov }
}
