import QtQuick
import Quickshell.Widgets
import "."

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
    required property int    index
    readonly property bool isReply: replyAuthor.length > 0 || replyText.length > 0
    width: ListView.view ? ListView.view.width : 600
    // extra height must match body's top margin so top/bottom padding stay even
    // (a grouped message with a reply line uses the larger 7px top margin).
    implicitHeight: body.implicitHeight + ((grouped && !isReply) ? 6 : 14)

    readonly property var reactions: JSON.parse(reactionsJson)
    readonly property var images: (imagesJson && imagesJson.length) ? JSON.parse(imagesJson) : []
    readonly property bool cursor: ListView.isCurrentItem && ListView.view && ListView.view.active
    readonly property bool emojiOnly: Backend.isEmojiOnly(text)

    Rectangle {
        anchors.fill: parent
        // No color/opacity animation here: the cursor must snap instantly so fast
        // j/k navigation doesn't catch rows mid-fade (reads as blinking).
        color: del.cursor ? Theme.selection
             : hov.hovered ? Qt.rgba(Theme.selection.r, Theme.selection.g, Theme.selection.b, 0.5) : "transparent"
        Rectangle {
            anchors.left: parent.left; width: 2; height: parent.height
            color: Theme.cursor; opacity: del.cursor ? 1 : 0
        }
    }

    // Brief accent pulse when this row is jumped to via a permalink.
    Rectangle {
        anchors.fill: parent
        color: Theme.sky
        opacity: (del.ListView.view && del.ListView.view.flashIndex === del.index) ? 0.28 : 0
        Behavior on opacity { NumberAnimation { duration: 320 } }
    }

    // vim relative line numbers (only while this list is the focused panel):
    // an orange dot marks the cursor row, the others show distance-from-cursor —
    // so "8j"/"3k" jumps are countable without a giant absolute line number.
    Item {
        visible: del.ListView.view && del.ListView.view.showNumbers
        anchors.left: parent.left; anchors.right: gutter.left
        // Center on the avatar (pfp) for a leading message; for a grouped message
        // (no avatar) center on its single text line instead.
        anchors.top: parent.top
        anchors.topMargin: del.grouped ? 3 : 9
        height: del.grouped ? 20 : 36
        Rectangle {
            visible: del.cursor; anchors.centerIn: parent
            width: 7; height: 7; radius: 3.5; color: Theme.cursor
        }
        Text { renderType: Text.QtRendering
            visible: !del.cursor
            anchors.right: parent.right; anchors.rightMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: Math.abs(del.index - del.ListView.view.currentIndex)
            color: Theme.fg_secondary
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 11; font.weight: 600
        }
    }

    // gutter: avatar (first in group) or hover-timestamp (continuation)
    Item {
        id: gutter
        x: 26; width: 40
        anchors.top: parent.top; anchors.topMargin: del.grouped ? 3 : 9
        height: 40
        ClippingRectangle {
            visible: !del.grouped
            width: 36; height: 36; radius: 8
            color: del.color                    // colored fallback behind the image

            Text { renderType: Text.QtRendering;
                anchors.centerIn: parent; text: del.initials; color: Theme.ink
                visible: avatarImg.status !== Image.Ready
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 14; font.weight: 800
            }
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
        Text { renderType: Text.QtRendering;
            visible: del.grouped && hov.hovered
            anchors.horizontalCenter: parent.horizontalCenter; y: 1
            text: del.time; color: Theme.fg_muted
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 11
        }
    }

    Column {
        id: body
        anchors.left: gutter.right; anchors.leftMargin: 10
        anchors.right: parent.right; anchors.rightMargin: 18
        anchors.top: parent.top; anchors.topMargin: del.grouped && !del.isReply ? 3 : 7
        spacing: 3

        // reply context (Discord): "↰ author  quoted snippet" above the message
        Row {
            visible: del.isReply
            width: parent.width
            spacing: 5
            Text { renderType: Text.QtRendering; text: "↰"; color: Theme.fg_muted
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13 }
            Text { renderType: Text.QtRendering; text: del.replyAuthor; color: Theme.sky
                   visible: del.replyAuthor.length > 0
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13; font.weight: 700 }
            Text { renderType: Text.QtRendering; text: del.replyText; color: Theme.fg_muted
                   width: Math.max(0, body.width - 140); elide: Text.ElideRight
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13 }
        }

        Row {
            visible: !del.grouped
            spacing: 8
            Text { renderType: Text.QtRendering; text: del.author; color: Theme.mode === "light" ? Theme.ink : Theme.fg
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 15; font.weight: 700 }
            Text { renderType: Text.QtRendering; text: del.time; color: Theme.fg_muted; anchors.bottom: parent.bottom; anchors.bottomMargin: 1
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12 }
        }

        Text { renderType: Text.QtRendering;
            visible: del.text.length > 0 && !del.emojiOnly
            width: parent.width
            text: Backend.richify(del.text, 22)
            // Light mode: plain black body text (the theme's secondary fg is a
            // purple that reads wrong for message content).
            color: Theme.mode === "light" ? Theme.ink : Theme.fg_secondary
            textFormat: Text.RichText
            wrapMode: Text.Wrap
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 15
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
                        renderType: Text.QtRendering
                        color: Theme.mode === "light" ? Theme.ink : Theme.fg
                        font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 36
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
                    readonly property real ar: (img.w > 0 && img.h > 0) ? img.h / img.w : 0.66
                    width: Math.min(maxW, img.w || maxW)
                    height: width * ar
                    // gifs animate inline (AnimatedImage); stills use Image.
                    // Only the matching element loads its source.
                    Image {
                        anchors.fill: parent
                        visible: img.type !== "gif"
                        source: img.type !== "gif" ? (img.path || "") : ""
                        fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: true
                        sourceSize.width: 760   // HiDPI-crisp at the inline cap
                    }
                    AnimatedImage {
                        anchors.fill: parent
                        visible: img.type === "gif"
                        source: img.type === "gif" ? (img.path || "") : ""
                        fillMode: Image.PreserveAspectCrop; cache: true
                        playing: visible; speed: 1.0
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
                        Text { renderType: Text.QtRendering; visible: pill._path === ""; text: modelData.e; font.pixelSize: 17
                               anchors.verticalCenter: parent.verticalCenter }
                        Text { renderType: Text.QtRendering; text: modelData.n; color: Theme.fg_muted
                               anchors.verticalCenter: parent.verticalCenter
                               font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 12; font.weight: 700 }
                    }
                }
            }
        }

        // thread indicator — Enter opens it
        Text { renderType: Text.QtRendering;
            visible: del.reply_count > 0
            topPadding: 3
            text: "  " + del.reply_count + (del.reply_count === 1 ? " reply" : " replies")
            color: Theme.sky
            font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting; font.pixelSize: 13; font.weight: 700
        }
    }

    HoverHandler { id: hov }
}
