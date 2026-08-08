import AppKit
import KeyboardShortcuts

/// The §3 menu-bar status item (SF Symbol, template image — adapts to menu
/// bar appearance). LSUIElement stays true; this is the only always-visible
/// entry point besides the notch itself.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let onOpenCapture: () -> Void
    private let onRunOnboarding: () -> Void
    private let onOpenSettings: () -> Void

    init(
        onOpenCapture: @escaping () -> Void,
        onRunOnboarding: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onOpenCapture = onOpenCapture
        self.onRunOnboarding = onRunOnboarding
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "rectangle.topthird.inset.filled",
                accessibilityDescription: "Ledge"
            )
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()

        let openCapture = NSMenuItem(
            title: "Open Capture",
            action: #selector(openCaptureAction),
            keyEquivalent: ""
        )
        openCapture.target = self
        // Shows (and live-syncs) the user's recorded hotkey next to the item.
        openCapture.setShortcut(for: .toggleCapture)
        menu.addItem(openCapture)

        let runChecks = NSMenuItem(
            title: "Run Onboarding Checks…",
            action: #selector(runOnboardingAction),
            keyEquivalent: ""
        )
        runChecks.target = self
        menu.addItem(runChecks)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Ledge",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc private func openCaptureAction() {
        onOpenCapture()
    }

    @objc private func runOnboardingAction() {
        onRunOnboarding()
    }

    @objc private func openSettingsAction() {
        onOpenSettings()
    }
}
