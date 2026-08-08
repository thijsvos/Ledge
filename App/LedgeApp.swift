import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchWindowController: NotchWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        notchWindowController = NotchWindowController()
    }

    func applicationWillTerminate(_: Notification) {
        notchWindowController?.teardown()
        notchWindowController = nil
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
