import QtQuick
import QtQuick.Controls
import QtQuick.Window
import "."

ListView {
    id: list
    clip: true
    model: Backend.messages
    delegate: MessageDelegate {}

    // Date dividers: messages are chronological, so grouping by the YYYYMMDD
    // `day` key gives one "—— Today ——" header per day. Helps avoid replying to
    // stale messages from an earlier day.
    section.property: "day"
    section.delegate: Item {
        id: secItem
        required property string section
        width: ListView.view.width; height: 34
        Rectangle { anchors.verticalCenter: parent.verticalCenter; x: 20; width: parent.width - 40
                    height: 1; color: Theme.hairline }
        Rectangle {
            anchors.centerIn: parent; height: 20; radius: 10
            width: dayLbl.implicitWidth + 22
            color: Theme.bg; border.color: Theme.hairline; border.width: 1
            Text { id: dayLbl; anchors.centerIn: parent; renderType: Text.QtRendering
                   text: Backend.dayLabel(secItem.section); color: Theme.fg_muted
                   font.family: Theme.fontFamily; font.hintingPreference: Font.PreferFullHinting
                   font.pixelSize: 12; font.weight: 700 }
        }
    }
    spacing: 0
    topMargin: 6
    bottomMargin: 10          // last message + reactions clear the composer
    boundsBehavior: Flickable.StopAtBounds
    // Realize the whole (small, ~60-msg) channel so contentHeight is EXACT and
    // positionViewAtEnd lands correctly. Virtualizing reintroduced both the
    // blank-on-open gap (async image heights) AND scroll unreliability. History
    // lazy-loads, so the realized set stays small.
    cacheBuffer: 1000000
    // Wheel scrolling must NOT snap back to the vim cursor — that was the
    // "scrolls me back down" bug. vim nav repositions explicitly instead.
    highlightFollowsCurrentItem: false

    property bool active: false       // focused panel? (drives selection highlight)
    property bool showNumbers: false  // relative line-number gutter (normal mode only)
    property bool stick: true     // follow new messages only while at the bottom

    // Self-heal when the OUTPUT changes — scale, resolution, or a monitor plug/unplug.
    // Item heights and contentHeight were computed for the old output and go stale,
    // which left scroll landing short until a restart. Keyed on the SCREEN's geometry +
    // scale (not the window's size, which also changes when the thread panel opens or
    // the composer grows), so it fires on display changes but not while you're typing.
    property string screenSig: Screen.width + "x" + Screen.height + "@" + Screen.devicePixelRatio
    onScreenSigChanged: Qt.callLater(function() {
        list.forceLayout()
        if (list.stick || list.pinBottom) list.goBottomNow()
    })

    // When the viewport shrinks (e.g. the typing row appears above the composer)
    // keep the newest message visible instead of letting it slide under.
    onHeightChanged: if (stick) Qt.callLater(goBottomNow)

    property real scrollGain: 5.0
    WheelHandler {
        acceptedDevices: PointerDevice.TouchPad | PointerDevice.Mouse
        onWheel: e => {
            list.pinBottom = false   // user took over; stop auto-pinning to bottom
            const px = (e.pixelDelta.y !== 0) ? e.pixelDelta.y : e.angleDelta.y / 8
            // Don't clamp to contentHeight (now an estimate under virtualization);
            // move, then let returnToBounds() snap into the valid range as rows
            // realize. Reliable without realizing the whole channel.
            const prevY = list.contentY
            list.contentY = list.contentY - px * list.scrollGain
            list.returnToBounds()
            list.stick = list.atYEnd
            if (list.contentY < prevY - 0.5) list.maybeLoadOlder()   // load older only while scrolling up
            e.accepted = true
        }
    }

    function pinIfStuck() { if (stick && count > 0) goBottomNow() }
    onCountChanged: Qt.callLater(pinIfStuck)

    // Opening a channel should land at the newest message. Content height keeps
    // growing as avatars/wrapped text settle, so one positionViewAtEnd lands
    // short — re-pin on every height change until the user scrolls or the
    // settle window ends.
    property bool pinBottom: false
    // Reach the TRUE bottom: realize the last item, then clamp contentY to the
    // exact end (section-safe + includes bottomMargin). Used for auto-pin and the
    // typing-row shrink — not by ctrl+d/u (those only fire goBottomNow via stick).
    function goBottomNow() {
        if (count <= 0) return
        positionViewAtIndex(count - 1, ListView.End)
        contentY = Math.max(0, contentHeight - height)
        returnToBounds()
        currentIndex = count - 1; stick = true
    }
    // Keep pinned while at the bottom (stick) — follows new messages and lets
    // content settle (images/wrapped text) without drifting up.
    onContentHeightChanged: if (pinBottom || stick) Qt.callLater(goBottomNow)
    Timer { id: pinTimer; interval: 600; onTriggered: list.pinBottom = false }

    Connections {
        target: Backend
        function onCurrentChannelChanged() {
            list.pinBottom = true; list.stick = true
            Qt.callLater(list.goBottomNow); pinTimer.restart()
        }
        // Capture the top-visible message AT INSERT TIME (not load-start, which goes
        // stale if you keep scrolling during the async fetch) plus its sub-pixel offset.
        function onAboutToPrepend() {
            const idx = list.indexAt(list.width / 2, list.contentY + 2)
            const row = idx >= 0 ? list.model.get(idx) : null
            if (row) {
                list._anchorTs = row.ts
                const it = list.itemAtIndex(idx)
                list._anchorOff = it ? (list.contentY - it.y) : 0
            } else {
                list._anchorTs = ""
            }
        }
        // Re-pin that message by INDEX (immune to async image/emoji heights settling
        // in the newly-loaded rows above — a raw contentY offset would drift).
        function onPrepended(n) {
            if (list.currentIndex >= 0) list.currentIndex += n
            if (list._anchorTs === "") return
            Qt.callLater(function() {
                for (let i = 0; i < list.count; i++) {
                    if (list.model.get(i).ts === list._anchorTs) {
                        list.positionViewAtIndex(i, ListView.Beginning)
                        list.contentY += list._anchorOff
                        list.returnToBounds()
                        break
                    }
                }
            })
        }
        // Sending a message jumps to the bottom so you see it land (and the
        // echo, which arrives a beat later, re-pins via the settle window).
        function onSentMessage() {
            list.stick = true; list.pinBottom = true
            Qt.callLater(list.goBottomNow); pinTimer.restart()
        }
        // Permalink/jump: the target message's window has loaded — scroll to it.
        function onJumpToMessage(ts) { Qt.callLater(function() { list.jumpToTs(ts) }) }
    }

    // Flash a just-jumped-to message briefly so the eye lands on it.
    property int flashIndex: -1
    Timer { id: flashTimer; interval: 1800; onTriggered: list.flashIndex = -1 }
    function jumpToTs(ts) {
        for (let i = 0; i < count; i++) {
            if (model.get(i).ts === ts) {
                currentIndex = i
                positionViewAtIndex(i, ListView.Center)
                stick = false
                flashIndex = i
                flashTimer.restart()
                return true
            }
        }
        return false
    }

    // Pull older history as the user nears the top. The wheel handler used to be the
    // only trigger, so keyboard nav (k/gg/ctrl-u) hit the loaded cap with nothing
    // loading. requestOlder() self-guards against re-entry and exhausted channels.
    property string _anchorTs: ""   // top-visible message at insert time (anchor)
    property real _anchorOff: 0     // its sub-pixel offset above the viewport top
    function maybeLoadOlder() {
        if (count <= 0 || Backend.loadingOlder) return
        if (currentIndex <= 6 || contentY < 400) Backend.requestOlder()
    }

    // vim nav (j/k/g/G/ctrl-d/u) — drives a message cursor
    function move(d) {
        currentIndex = Math.max(0, Math.min(count - 1, currentIndex + d))
        // Snap fully to the bottom on the last message (Contain only scrolls it
        // just-visible, leaving it short of the end under the composer).
        if (currentIndex >= count - 1) positionViewAtIndex(count - 1, ListView.End)
        else positionViewAtIndex(currentIndex, ListView.Contain)
        stick = atYEnd || currentIndex >= count - 1
        if (d < 0) maybeLoadOlder()
    }
    // ctrl+e / ctrl+y: nudge the view by ~3 lines WITHOUT moving the cursor.
    function scroll(d) {
        const maxY = Math.max(0, contentHeight - height)
        contentY = Math.max(0, Math.min(maxY, contentY + d * 48))
        stick = atYEnd
        if (d < 0) maybeLoadOlder()
    }
    function toTop()    { currentIndex = 0; positionViewAtBeginning(); stick = false; maybeLoadOlder() }
    function toBottom() { currentIndex = count - 1; positionViewAtIndex(count - 1, ListView.End); stick = true }
    // Half-page scroll by half the viewport height (messages vary in height —
    // a fixed row count was a full screen once images are in play). Cursor
    // follows to a still-visible item without re-scrolling.
    function half(d) {
        const maxY = Math.max(0, contentHeight - height)
        contentY = Math.max(0, Math.min(maxY, contentY + d * height * 0.5))
        // Scrolling down into the bottom: snap fully to the last message and
        // follow new ones, so ctrl+d reliably lands you at the end.
        if (d > 0 && contentY >= maxY - 4) {
            currentIndex = count - 1
            positionViewAtIndex(count - 1, ListView.End)
            stick = true
            return
        }
        const idx = indexAt(width / 2, contentY + height / 2)
        if (idx >= 0) currentIndex = idx
        stick = atYEnd
        if (d < 0) maybeLoadOlder()
    }
    function currentMessage() { return (currentIndex >= 0 && currentIndex < count) ? model.get(currentIndex) : null }

    // No add/displaced y-animations: under rapid live inserts they stacked and
    // left delegates overlapping. Messages just appear.

    ScrollBar.vertical: ScrollBar { width: 8; policy: ScrollBar.AsNeeded }
}
