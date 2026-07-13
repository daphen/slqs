// Nucleo icon, theme-tinted. name is the bare icon name; fill/size pick a
// variant (glyph|outline|outline-duo|glyph-duo × 12|18); bare glyph-18 is
// the default. White-fill sources are colorized to `color`.
import QtQuick
import QtQuick.Effects

Item {
    id: root
    property string name: ""
    property color color: Theme.fg_muted
    property string fill: ""      // "" = default (glyph)
    property int variantSize: 0   // 0 = default (18)
    implicitWidth: 18
    implicitHeight: 18

    readonly property string _file: fill !== "" || variantSize !== 0
        ? name + "--" + (fill || "glyph") + "--" + (variantSize || 18)
        : name

    Image {
        id: img
        anchors.fill: parent
        source: root.name !== "" ? Qt.resolvedUrl("icons/" + root._file + ".svg") : ""
        sourceSize.width: 64
        sourceSize.height: 64
        visible: false
        asynchronous: true
    }
    MultiEffect {
        anchors.fill: img
        source: img
        colorization: 1
        colorizationColor: root.color
    }
}
