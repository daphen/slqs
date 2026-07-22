pragma Singleton
import QtQuick

// Centralized motion tokens for the quickshell app family. Durations and
// easings live here (not in the generated Theme.qml) because motion is not
// theme-dependent. Values are derived from what the apps already used, so
// migrating a scattered literal to the matching token preserves its timing.
//
// Usage:
//   Behavior on opacity { NumberAnimation { duration: Motion.fast } }
//   NumberAnimation { duration: Motion.slow; easing.type: Motion.easeSymmetric }
//   NumberAnimation { duration: Motion.base
//                     easing.type: Motion.easeEmphasized
//                     easing.bezierCurve: Motion.curveEmphasized }
QtObject {
    // Durations (ms)
    readonly property int fast: 100   // fades: pickers, dropdowns, hover states
    readonly property int base: 120   // small property transitions (height, radius)
    readonly property int med: 200    // medium moves
    readonly property int slow: 250   // larger opacity/scale transitions
    readonly property int pulse: 550  // attention pulses (FeedbackPill)

    // Easing types
    readonly property int easeSymmetric: Easing.InOutQuad  // in-and-out, symmetric
    readonly property int easeOut: Easing.OutCubic         // enter / settle
    readonly property int easeEmphasized: Easing.BezierSpline

    // Signature bezier curves — pass to easing.bezierCurve with
    // easing.type: Motion.easeEmphasized. Each ends at the required (1,1).
    readonly property var curveEmphasized: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0]  // primary decel
    readonly property var curveDecel: [0.165, 0.84, 0.44, 1.0, 1.0, 1.0]      // strong ease-out
    readonly property var curveOvershoot: [0.34, 1.56, 0.64, 1.0, 1.0, 1.0]   // back-out spring
}
