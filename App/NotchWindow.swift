import AppKit

/// §4 notch panel. Its frame is ALWAYS the constant expanded maximum for the
/// current screen; the SwiftUI shape animates inside it — the window is never
/// resized during animation.
final class NotchWindow: NSPanel {
    /// Focus discipline (§4): the panel may become key ONLY while the island
    /// is `.open`. `NotchWindowController` flips this around transitions so
    /// typing in other apps is never intercepted while collapsed.
    var allowsKeyStatus = false

    override var canBecomeKey: Bool {
        allowsKeyStatus
    }

    override var canBecomeMain: Bool {
        false
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // shadow ON only while .open (toggled by the controller)
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }
}
