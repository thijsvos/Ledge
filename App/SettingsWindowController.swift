import AppKit
import SwiftUI

/// The §7 Settings window.
///
/// DOCUMENTED DEVIATION from the architecture doc: §7 names a SwiftUI
/// `Settings` scene, but that scene only exists under the SwiftUI App
/// lifecycle — Ledge runs the AppKit lifecycle (NSApplication + delegate,
/// required for the notch panel discipline). The scene is therefore realized
/// as a manually-presented NSWindow hosting `NSHostingView(SettingsView)`.
///
/// Window rules (§7 binding decisions): titled, closable, centered, single
/// instance, and it ACTIVATES the app while open — it is a normal window; the
/// notch panel's never-activate rules do NOT apply to it. It also hosts the
/// onboarding sheet (first launch + on demand) — the sheet lives here, never
/// on the notch panel.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hosting: NSHostingController<SettingsView>?
    /// Monotonic counter passed into SettingsView; bumping it on
    /// `windowDidBecomeKey` re-renders the view so the login-item status and
    /// the path-validity rows re-check reality (the user typically changed
    /// them in System Settings or Finder, which deactivated Ledge).
    private var refreshTick = 0
    private let onboarding: OnboardingController
    private var onboardingSheet: NSViewController?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboarding = OnboardingController(defaults: defaults)
        super.init()
    }

    /// Shows (or brings forward) the single Settings window.
    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens Settings and presents the onboarding sheet on it (§7: sheet on
    /// the SETTINGS window, auto on first launch and on demand).
    func showOnboarding() {
        show()
        guard onboardingSheet == nil, let host = window?.contentViewController else { return }
        onboarding.refresh()
        let sheet = NSHostingController(
            rootView: OnboardingView(
                controller: onboarding,
                onDone: { [weak self] in self?.dismissOnboarding() }
            )
        )
        host.presentAsSheet(sheet)
        onboardingSheet = sheet
    }

    private func dismissOnboarding() {
        if let onboardingSheet {
            window?.contentViewController?.dismiss(onboardingSheet)
        }
        onboardingSheet = nil
        // Finishing the sheet (Done) is what counts as "has run onboarding" —
        // quitting mid-sheet re-presents on the next launch.
        defaults.set(true, forKey: DefaultsKey.hasRunOnboarding)
    }

    /// Builds the one Settings window. `isReleasedWhenClosed = false` is what
    /// makes it single-instance: closing must leave the object alive so `show()`
    /// brings the same window — and whatever onboarding-sheet state it holds —
    /// back, instead of building a second one behind the first.
    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: currentSettingsView())
        self.hosting = hosting
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Ledge Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func currentSettingsView() -> SettingsView {
        SettingsView(
            refreshTick: refreshTick,
            onRunChecks: { [weak self] in self?.showOnboarding() }
        )
    }

    // MARK: - NSWindowDelegate

    /// Fires when the user comes back to the window (from System Settings,
    /// Finder, …): bump the tick so SettingsView re-checks the login-item
    /// status and both path validities against the live world.
    func windowDidBecomeKey(_: Notification) {
        refreshTick += 1
        hosting?.rootView = currentSettingsView()
    }

    func windowWillClose(_: Notification) {
        // An open sheet is dismissed with its window; count it as finished so
        // first-launch onboarding doesn't loop forever for a user who closed
        // the window instead of tapping Done.
        if onboardingSheet != nil {
            onboardingSheet = nil
            defaults.set(true, forKey: DefaultsKey.hasRunOnboarding)
        }
    }
}
