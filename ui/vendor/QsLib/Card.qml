import QtQuick

// Floating surface on the window canvas — the family's main content
// container (mail index, chat pane, agenda, thread panel). Consumers
// anchor it themselves; nested boxes inset by Theme.insetCard and use
// Theme.radiusInner to stay concentric.
Rectangle {
    radius: Theme.radiusCard
    color: Theme.bg
}
