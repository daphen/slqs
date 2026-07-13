import QtQuick

// Family scroll feel for any Flickable — declare inside the list:
//
//   Lib.ScrollFeel { flick: list; onScrolled: up => { ... } }
//
// Mouse wheels get a 5x notch gain (Qt's default is treacle); touchpads
// scroll from angleDelta at a measured gain — their pixelDeltas arrive
// junk-scaled (1–5px/event) on this hardware, so they are ignored.
WheelHandler {
    id: root
    required property Flickable flick
    property real mouseGain: 5.0
    property real touchpadGain: 1.2
    // fires after each wheel-driven move; up === scrolled toward older content
    signal scrolled(bool up)

    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: e => {
        const touchpad = point.device.type === PointerDevice.TouchPad
        const px = touchpad
            ? e.angleDelta.y * touchpadGain
            : ((e.pixelDelta.y !== 0) ? e.pixelDelta.y : e.angleDelta.y / 8) * mouseGain
        flick.contentY -= px
        flick.returnToBounds()
        root.scrolled(px > 0)
        e.accepted = true
    }
}
