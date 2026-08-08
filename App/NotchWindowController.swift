import AppKit
import KeyboardShortcuts
import LedgeCore
import SwiftUI

/// Root SwiftUI view: observes `IslandController` (via Observation) and hands
/// interaction callbacks back to the window controller.
struct NotchRootView: View {
    var island: IslandController
    var layout: IslandLayout
    var reduceMotion: Bool
    var onHoverChanged: (Bool) -> Void
    var onTap: () -> Void
    var onSubmit: (String) -> Void
    var captureRestoreInput: () -> String?
    var onOpenInTerminal: (ResumeAction) -> Void
    var onCopyCommand: (ResumeAction) -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        IslandView(
            state: island.state,
            layout: layout,
            reduceMotion: reduceMotion,
            onHoverChanged: onHoverChanged,
            onIslandTap: onTap,
            onSubmit: onSubmit,
            captureRestoreInput: captureRestoreInput,
            onOpenInTerminal: onOpenInTerminal,
            onCopyCommand: onCopyCommand,
            onOpenSettings: onOpenSettings
        )
    }
}

/// Owns the notch panel: geometry, monitors, hover debounce, focus discipline.
/// All island mutations still flow through `IslandController.transition(to:)`.
@MainActor
final class NotchWindowController: NSObject {
    let island: IslandController

    /// Opens the Settings window; wired by AppDelegate. Fired by tapping a
    /// configuration-failure peek (or its "Open Settings…" button) — §7
    /// empty/error-states pass.
    var onOpenSettings: (() -> Void)?

    private let agentRunController: AgentRunController
    private let captureCoordinator: CaptureCoordinator
    private let window: NotchWindow
    private let hostingView: NSHostingView<NotchRootView>
    private var geometry: IslandGeometry
    private var layout: IslandLayout
    /// §7 reduced motion: tracked from NSWorkspace and plumbed into
    /// IslandView, where IslandMotion swaps the spring for a ~150 ms fade.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var hoverTask: Task<Void, Never>?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?

    override init() {
        let island = IslandController()
        self.island = island
        // Phase-3 wiring (§6): the runner façade adopts AgentRunSubmitting;
        // `/` prompts flow CaptureView → CaptureCoordinator → AgentRunController.
        let agentRunController = AgentRunController(island: island)
        self.agentRunController = agentRunController
        captureCoordinator = CaptureCoordinator(island: island, agentRunner: agentRunController)
        let snapshot = Self.currentScreenSnapshot()
        let geometry = NotchGeometry.geometry(for: snapshot)
        self.geometry = geometry
        layout = IslandLayout(geometry: geometry)
        window = NotchWindow(contentRect: geometry.windowFrame)
        hostingView = NSHostingView(
            rootView: NotchRootView(
                island: island,
                layout: layout,
                reduceMotion: false,
                onHoverChanged: { _ in },
                onTap: {},
                onSubmit: { _ in },
                captureRestoreInput: { nil },
                onOpenInTerminal: { _ in },
                onCopyCommand: { _ in },
                onOpenSettings: {}
            )
        )
        super.init()

        // A `/` submission rejected before it ever ran hands the prompt back
        // so the field restores it on the next open — the raw input for an
        // agent route is "/" + prompt (§5 router). Typed text is never lost.
        agentRunController.onSubmissionRejected = { [weak self] prompt in
            self?.captureCoordinator.preserveInput("/" + prompt)
        }

        hostingView.frame = CGRect(origin: .zero, size: geometry.windowFrame.size)
        window.contentView = hostingView
        installRootView()
        window.setFrame(geometry.windowFrame, display: true)
        window.orderFrontRegardless()

        installMonitors()
        installObservers()
        installHotkey()
        observeIslandState()
        applyWindowSideEffects()
    }

    /// Removes monitors and observers, and SIGTERMs any live agent run (§6:
    /// app quit with a live run terminates the child, persists nothing).
    /// Called from `applicationWillTerminate`; monitors must not outlive the
    /// controller.
    func teardown() {
        agentRunController.shutdown()
        hoverTask?.cancel()
        hoverTask = nil
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        window.orderOut(nil)
    }

    // MARK: - Screen selection & geometry

    /// Prefer the notched built-in display; otherwise the main screen.
    private static func currentScreenSnapshot() -> ScreenSnapshot {
        let snapshots = NSScreen.screens.map { ScreenSnapshot(screen: $0) }
        if let notched = snapshots.first(where: NotchGeometry.hasNotch) {
            return notched
        }
        if let main = NSScreen.main {
            return ScreenSnapshot(screen: main)
        }
        return snapshots.first ?? ScreenSnapshot(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTopInset: 0
        )
    }

    /// Recompute on screen-parameter changes and wake (§4); track the
    /// system's reduce-motion setting (§7).
    private func installObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(environmentDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(environmentDidChange),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func environmentDidChange(_: Notification) {
        recomputeGeometry()
    }

    @objc private func accessibilityDisplayOptionsDidChange(_: Notification) {
        let updated = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard updated != reduceMotion else { return }
        reduceMotion = updated
        installRootView()
    }

    private func recomputeGeometry() {
        let updated = NotchGeometry.geometry(for: Self.currentScreenSnapshot())
        guard updated != geometry else { return }
        geometry = updated
        layout = IslandLayout(geometry: updated)
        // Repositioning to a new screen configuration is not an animation —
        // the frame is still "the expanded maximum" for the current screen.
        window.setFrame(updated.windowFrame, display: true)
        installRootView()
    }

    private func installRootView() {
        hostingView.rootView = NotchRootView(
            island: island,
            layout: layout,
            reduceMotion: reduceMotion,
            onHoverChanged: { [weak self] hovering in self?.hoverChanged(hovering) },
            onTap: { [weak self] in self?.islandTapped() },
            onSubmit: { [weak self] input in self?.captureCoordinator.submit(input) },
            captureRestoreInput: { [weak self] in self?.captureCoordinator.consumeRestoreInput() },
            onOpenInTerminal: { [weak self] resume in self?.agentRunController.openInTerminal(resume) },
            onCopyCommand: { [weak self] resume in self?.agentRunController.copyCommand(resume) },
            onOpenSettings: { [weak self] in self?.openSettingsFromPeek() }
        )
    }

    // MARK: - Interaction

    /// Hover with the shared 80 ms debounce; exit collapses immediately.
    private func hoverChanged(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        if hovering {
            guard island.state == .collapsed else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: IslandMotion.hoverDebounce)
                guard let self, !Task.isCancelled else { return }
                if island.state == .collapsed {
                    island.transition(to: .hover)
                }
            }
        } else if island.state == .hover {
            island.transition(to: .collapsed)
        }
    }

    /// Click on the island. A configuration-failure peek (no resume, cause is
    /// setup) routes the tap to Settings (§7 empty/error-states pass); any
    /// other state opens the capture field.
    private func islandTapped() {
        hoverTask?.cancel()
        hoverTask = nil
        if case let .peek(.failure(_, resume, configuration)) = island.state,
           resume == nil, configuration
        {
            openSettingsFromPeek()
            return
        }
        island.transition(to: .open)
    }

    /// §7 global hotkey (default ⌥Space, recorded in Settings): toggle — if
    /// the island is `.open`, dismiss (the exact Esc path); otherwise open,
    /// which makes the panel key. Works from any app; the KeyboardShortcuts
    /// handler captures `self` weakly so the listener can never retain-cycle
    /// (or revive) the controller.
    func toggleCapture() {
        hoverTask?.cancel()
        hoverTask = nil
        if island.state == .open {
            dismissToIdle()
        } else {
            island.transition(to: .open)
        }
    }

    private func installHotkey() {
        KeyboardShortcuts.onKeyUp(for: .toggleCapture) { [weak self] in
            self?.toggleCapture()
        }
    }

    /// Configuration-failure peeks guide the user to Settings; the peek is
    /// dismissed so it doesn't linger behind the Settings window.
    private func openSettingsFromPeek() {
        dismissToIdle()
        onOpenSettings?()
    }

    /// Dismissing the open island returns it to idle, which is NOT always
    /// `.collapsed`: while an agent run is live the island must keep showing
    /// the status dot (§1 "a small status dot shows a run is live"; §4
    /// `.running` == collapsed + dot). Mirrors `IslandController`'s peek
    /// expiry fallback (`.running(liveRun)` if set, else `.collapsed`).
    private func dismissToIdle() {
        if let run = island.liveRun {
            island.transition(to: .running(run))
        } else {
            island.transition(to: .collapsed)
        }
    }

    /// Esc + click-outside monitors (§4), removed in `teardown()`.
    private func installMonitors() {
        // Esc dismisses while open; swallowed so it doesn't leak elsewhere.
        // (Local monitors run synchronously on the main thread.)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 53, self.island.state == .open else {
                    return false
                }
                self.dismissToIdle()
                return true
            }
            return swallow ? nil : event
        }

        // Clicks routed to our own windows: dismiss when outside the shape.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleLocalMouseDown(event)
            }
            return event
        }

        // Clicks anywhere in other apps: dismiss. (Global monitors only
        // observe; the click still lands in the other app, which is what we
        // want — running/peek overlays never steal focus either.)
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, island.state == .open else { return }
                dismissToIdle()
            }
        }
    }

    private func handleLocalMouseDown(_ event: NSEvent) {
        guard island.state == .open else { return }
        guard event.window === window else {
            dismissToIdle()
            return
        }
        // Same numbers IslandView draws with: shape is top-centered in the
        // constant window frame.
        let size = IslandView.shapeSize(for: island.state, layout: layout)
        let shapeRect = CGRect(
            x: (window.frame.width - size.width) / 2,
            y: window.frame.height - size.height,
            width: size.width,
            height: size.height
        )
        if !shapeRect.contains(event.locationInWindow) {
            dismissToIdle()
        }
    }

    // MARK: - Window side effects (shadow + key status)

    /// Re-armed observation of `island.state`; applies window-level effects
    /// for transitions from ANY source (UI handlers now, runner in Phase 3).
    private func observeIslandState() {
        withObservationTracking {
            _ = island.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                applyWindowSideEffects()
                observeIslandState()
            }
        }
    }

    private func applyWindowSideEffects() {
        let isOpen = island.state == .open
        window.hasShadow = isOpen // §4: shadow ON only when open
        if isOpen {
            window.allowsKeyStatus = true
            window.makeKeyAndOrderFront(nil)
        } else if window.allowsKeyStatus || window.isKeyWindow {
            // Focus discipline: once no longer open the panel must never hold
            // key status, or it would swallow keystrokes meant for other apps.
            // canBecomeKey now returns false; the brief orderOut/orderFront
            // cycle forces AppKit to hand key status back to the previously
            // key window (becomeKey/resignKey must not be called directly).
            window.allowsKeyStatus = false
            if window.isKeyWindow {
                window.orderOut(nil)
                window.orderFrontRegardless()
            }
        }
    }
}
