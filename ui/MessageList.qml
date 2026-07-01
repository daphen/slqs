import QtQuick
import QtQuick.Controls
import QtQuick.Window
import "."

ListView {
    id: list
    clip: true
    model: Backend.messages
    delegate: MessageDelegate {}

    // Date dividers are now rendered per-row inside MessageDelegate (first message
    // of each day), not via ListView sections — section headers mis-dated rows
    // after image reflows because their delegates didn't refresh their date.
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
        if (list.stick || list.pinBottom) list.pinBottomView()
    })

    // When the viewport shrinks (e.g. the typing row appears above the composer)
    // keep the newest message visible instead of letting it slide under.
    onHeightChanged: if (stick) Qt.callLater(pinBottomView)

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
    // The true max scroll: Flickable adds bottomMargin BEYOND contentHeight, so
    // the real bottom is contentHeight - height + bottomMargin. Using
    // contentHeight - height alone stops bottomMargin short (the wheel, via
    // returnToBounds, reaches further — keyboard nav must match it).
    function bottomY() { return Math.max(0, contentHeight - height + bottomMargin) }
    function goBottomNow() {
        if (count <= 0) return
        positionViewAtIndex(count - 1, ListView.End)
        contentY = bottomY()
        returnToBounds()
        currentIndex = count - 1; stick = true
    }
    // Scroll the view to the true bottom WITHOUT moving the cursor — for content
    // that resizes in place (reactions, image settling), where goBottomNow would
    // yank the highlight to the last message.
    function pinBottomView() { if (count > 0) contentY = bottomY() }
    // Keep pinned while at the bottom (stick) — follows new messages and lets
    // content settle (images/wrapped text) without drifting up.
    onContentHeightChanged: if (pinBottom || stick) pinBottomView()
    Timer { id: pinTimer; interval: 600; onTriggered: list.pinBottom = false }

    Connections {
        target: Backend
        // optimistic insert/reconcile changed item heights in place → re-flow so
        // section (date) dividers don't render at stale positions over messages.
        function onReflowList() {
            // Re-pin the VIEW (not the cursor) if it was at the bottom. atYEnd reads
            // false even at contentY==maxY, so compare contentY to the end directly.
            const wasBottom = list.stick || list.contentY >= list.bottomY() - 8
            Qt.callLater(function() {
                list.forceLayout()
                if (wasBottom) list.contentY = list.bottomY()
            })
        }
        // A reaction only resizes a row (never changes its day), so skip the
        // forceLayout re-flow (that flashed the whole list). Detect bottom BEFORE
        // the chip grows the row, then let the settle window re-pin via
        // onContentHeightChanged when contentHeight actually updates.
        function onReactionChanged() {
            if (list.stick || list.contentY >= list.bottomY() - 8) {
                list.pinBottom = true
                pinTimer.restart()
            }
        }
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

    // vim nav (j/k/g/G/ctrl-d/u) — drives a message cursor, but first scrolls
    // THROUGH a message taller than the viewport before stepping to the next.
    function move(d) {
        const it = (currentIndex >= 0 && currentIndex < count) ? itemAtIndex(currentIndex) : null
        if (it) {
            const maxY = bottomY()
            const step = height * 0.85
            if (d > 0 && it.y + it.height > contentY + height + 1) {
                contentY = Math.min(maxY, Math.min(it.y + it.height - height, contentY + step))
                stick = atYEnd
                return
            }
            if (d < 0 && it.y < contentY - 1) {
                contentY = Math.max(it.y, contentY - step)
                stick = false; maybeLoadOlder()
                return
            }
        }
        currentIndex = Math.max(0, Math.min(count - 1, currentIndex + d))
        // Snap fully to the bottom on the last message (Contain only scrolls it
        // just-visible, leaving it short of the end under the composer).
        if (currentIndex >= count - 1) {
            positionViewAtIndex(count - 1, ListView.End)
            contentY = bottomY()   // true bottom incl. bottomMargin (End alone lands short)
        } else {
            positionViewAtIndex(currentIndex, ListView.Contain)
            // Taller than the viewport: align its leading edge so the next j/k
            // scrolls through it (top when going down, bottom when going up).
            const t = itemAtIndex(currentIndex)
            if (t && t.height > height)
                positionViewAtIndex(currentIndex, d > 0 ? ListView.Beginning : ListView.End)
        }
        stick = atYEnd || currentIndex >= count - 1
        if (d < 0) maybeLoadOlder()
    }
    // ctrl+e / ctrl+y: nudge the view by ~3 lines WITHOUT moving the cursor.
    function scroll(d) {
        const maxY = bottomY()
        contentY = Math.max(0, Math.min(maxY, contentY + d * 48))
        stick = atYEnd
        if (d < 0) maybeLoadOlder()
    }
    function toTop()    { currentIndex = 0; positionViewAtBeginning(); stick = false; maybeLoadOlder() }
    function toBottom() { currentIndex = count - 1; positionViewAtIndex(count - 1, ListView.End); contentY = bottomY(); stick = true }
    // Half-page scroll by half the viewport height (messages vary in height —
    // a fixed row count was a full screen once images are in play). Cursor
    // follows to a still-visible item without re-scrolling.
    function half(d) {
        // Move the cursor by ~half a screen of PIXELS relative to where it is, so it
        // adapts to message height and works whether the channel scrolls or fits on
        // screen. Clamp to the ends; scroll only to keep the cursor visible.
        const it = itemAtIndex(currentIndex)
        const baseY = it ? it.y + it.height / 2 : contentY + height / 2
        let idx = indexAt(width / 2, baseY + d * height * 0.5)
        if (idx < 0) idx = (d > 0) ? count - 1 : 0
        currentIndex = Math.max(0, Math.min(count - 1, idx))
        if (currentIndex >= count - 1) { positionViewAtIndex(count - 1, ListView.End); contentY = bottomY() }
        else positionViewAtIndex(currentIndex, ListView.Contain)
        stick = atYEnd || currentIndex >= count - 1
        if (d < 0) maybeLoadOlder()
    }
    function currentMessage() { return (currentIndex >= 0 && currentIndex < count) ? model.get(currentIndex) : null }

    // No add/displaced y-animations: under rapid live inserts they stacked and
    // left delegates overlapping. Messages just appear.

    ScrollBar.vertical: ScrollBar { width: 8; policy: ScrollBar.AsNeeded }
}
