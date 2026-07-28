// Canonical loading spinner for the quickshell family. The "Diagswipe" braille
// animation (frames from vyfor/rattles), but rendered as an actual dot grid
// rather than braille glyphs — GUI fonts draw unset braille dots as visible
// circles (and sometimes colour them), which reads as a broken grid. Decoding
// each frame to lit/blank dots gives one colour, even spacing, truly-blank gaps.
// Override `frames` / `interval` for a different rattles animation.
//
//   Spinner { running: busy; color: Theme.fg }
import QtQuick

Item {
    id: sp
    property bool running: false
    property int interval: 60            // ms per frame
    property color color: Theme.fg
    property real dotSize: 2.2
    property real dotGap: 2.0
    property var frames: [
        "⠁⠀", "⠋⠀", "⠟⠁", "⡿⠋", "⣿⠟", "⣿⡿", "⣿⣿", "⣿⣿",
        "⣾⣿", "⣴⣿", "⣠⣾", "⢀⣴", "⠀⣠", "⠀⢀", "⠀⠀", "⠀⠀"
    ]

    readonly property int _cells: (frames.length && frames[0]) ? frames[0].length : 2
    readonly property int _cols: _cells * 2
    readonly property int _rows: 4

    // braille bit → [localCol, row] within a 2×4 cell
    readonly property var _map: ({ 1:[0,0], 2:[0,1], 4:[0,2], 64:[0,3], 8:[1,0], 16:[1,1], 32:[1,2], 128:[1,3] })
    function _decode(fr) {
        const grid = new Array(sp._cols * sp._rows).fill(false)
        for (let c = 0; c < sp._cells; c++) {
            const code = (fr.charCodeAt(c) || 0x2800) - 0x2800
            for (const bit in sp._map) {
                if (code & bit) {
                    const col = c * 2 + sp._map[bit][0]
                    const rowv = sp._map[bit][1]
                    grid[rowv * sp._cols + col] = true
                }
            }
        }
        return grid
    }

    property real _t: 0
    readonly property int _fi: Math.min(frames.length - 1, Math.floor(_t * frames.length))
    readonly property var _grid: _decode(frames[_fi])

    implicitWidth: _cols * dotSize + (_cols - 1) * dotGap
    implicitHeight: _rows * dotSize + (_rows - 1) * dotGap
    width: implicitWidth; height: implicitHeight

    Grid {
        anchors.centerIn: parent
        columns: sp._cols; rows: sp._rows
        columnSpacing: sp.dotGap; rowSpacing: sp.dotGap
        Repeater {
            model: sp._cols * sp._rows
            delegate: Rectangle {
                required property int index
                width: sp.dotSize; height: sp.dotSize; radius: sp.dotSize / 2
                color: sp.color
                opacity: sp._grid[index] ? 1 : 0   // keep the grid slot; blank = invisible
            }
        }
    }

    NumberAnimation on _t {
        running: sp.running
        from: 0; to: 1
        duration: Math.max(1, sp.interval * sp.frames.length)
        loops: Animation.Infinite
    }
}
