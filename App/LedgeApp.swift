import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchWindowController: NotchWindowController?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        // §10 cold-launch hook: ONE signpost event + one Logger line
        // (subsystem app.ledge, category perf). scripts/perf-check.sh times
        // process spawn → this line via `log stream`. No other launch
        // instrumentation exists — and the app gains no timers or polling.
        OSSignposter(subsystem: "app.ledge", category: "perf").emitEvent("app.launched")
        Logger(subsystem: "app.ledge", category: "perf").notice("launched")

        let notch = NotchWindowController()
        notchWindowController = notch
        let settings = SettingsWindowController()
        settingsWindowController = settings

        // Configuration-failure peeks ("no vault", "no binary") open Settings.
        notch.onOpenSettings = { [weak settings] in
            settings?.show()
        }

        statusItemController = StatusItemController(
            onOpenCapture: { [weak notch] in notch?.toggleCapture() },
            onRunOnboarding: { [weak settings] in settings?.showOnboarding() },
            onOpenSettings: { [weak settings] in settings?.show() }
        )

        installMainMenu()

        // First launch (UserDefaults "hasRunOnboarding" != true): auto-present
        // the onboarding sheet on the Settings window (§7).
        if !UserDefaults.standard.bool(forKey: DefaultsKey.hasRunOnboarding) {
            settings.showOnboarding()
        }
    }

    func applicationWillTerminate(_: Notification) {
        notchWindowController?.teardown()
        notchWindowController = nil
    }

    /// LSUIElement apps have no visible menu bar, but a main menu is still
    /// what makes ⌘, / ⌘Q / edit shortcuts work while the Settings window is
    /// key (the notch panel never needs this — it swallows only Esc).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit Ledge",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMenu() {
        settingsWindowController?.show()
    }
}

@main
@MainActor
enum LedgeMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Launch flags run BEFORE app.run() and exit the process (§9 Phase 1).
        if let exitCode = LaunchFlags.handle(Array(CommandLine.arguments.dropFirst())) {
            exit(exitCode)
        }

        app.delegate = delegate
        app.run()
    }
}
