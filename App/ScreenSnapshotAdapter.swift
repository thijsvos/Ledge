import AppKit
import LedgeCore

extension ScreenSnapshot {
    /// AppKit → pure-value adapter. LedgeCore never imports AppKit; this is
    /// the only place NSScreen crosses into geometry.
    @MainActor
    init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }
}
