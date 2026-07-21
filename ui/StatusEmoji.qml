// A user's custom status emoji: unicode glyphs as text, ":name:" (workspace
// custom emoji, slqs) via the cached emoji map, URLs (Discord CDN) directly.
// Collapses when there's no status.
import QtQuick
import "."

Item {
    id: se
    property string emoji: ""
    property int px: 14
    readonly property bool isUrl: emoji.startsWith("http") || emoji.startsWith("file:")
    readonly property bool isCustom: !isUrl && emoji.startsWith(":")
    readonly property string src: isUrl ? emoji
                                : isCustom ? Backend.emojiPath(emoji.slice(1, -1)) : ""
    visible: emoji !== "" && (src !== "" || (!isUrl && !isCustom))
    width: px
    height: px

    Text {
        visible: se.src === ""
        anchors.centerIn: parent
        text: se.emoji
        font.pixelSize: se.px - 2
    }
    Image {
        visible: se.src !== ""
        anchors.fill: parent
        source: se.src
        sourceSize.width: se.px * 2
        sourceSize.height: se.px * 2
        fillMode: Image.PreserveAspectFit
        asynchronous: true
    }
}
