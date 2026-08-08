import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The §7 global capture hotkey. Default ⌥Space — declared HERE and only
    /// here; Settings shows a `KeyboardShortcuts.Recorder` for it and
    /// `NotchWindowController` listens via `onKeyUp`.
    static let toggleCapture = Self("toggleCapture", default: .init(.space, modifiers: [.option]))
}
