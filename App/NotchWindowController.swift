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
    var suggestionModel: SlashSuggestionModel
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
            suggestionModel: suggestionModel,
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
    /// empty/error-states pass — and by the `/settings` native command.
    var onOpenSettings: (() -> Void)?

    /// Presents the onboarding checks sheet; wired by AppDelegate. Fired by
    /// the `/checks` native command.
    var onRunChecks: (() -> Void)?

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

    /// Slash-command typeahead (user-requested addition beyond the MVP spec):
    /// the model the capture field binds to and the local key monitor drives.
    /// Its suggestion source is the STATIC native-command list (LedgeCore's
    /// `NativeCommand`) — nothing to scan for the UI.
    private let suggestionModel = SlashSuggestionModel()
    /// The user's Claude Code commands/skills, rescanned by
    /// `scanSlashCommands()` once per transition into `.open` — event-driven,
    /// zero polling/timers/watchers (§10). NOT shown in the suggestion list
    /// (that lists Ledge's native commands); kept solely for
    /// CaptureCoordinator's submit-time slash restoration, so a typed Claude
    /// command ("/vet …") still reaches the CLI as a command, invisibly.
    private var scannedCatalog = SlashCommandCatalog()
    private var suggestionScanTask: Task<Void, Never>?

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
                suggestionModel: suggestionModel,
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
        // agent route is "/" + prompt (§5 router), except when the submit
        // path already restored the slash for a known command (the prompt
        // then IS the raw input; never double the slash). Typed text is
        // never lost.
        agentRunController.onSubmissionRejected = { [weak self] prompt in
            self?.captureCoordinator.preserveInput(
                prompt.hasPrefix("/") ? prompt : "/" + prompt
            )
        }

        // Submit-time slash restoration: CaptureRouter strips the leading
        // "/" (§5), but headless claude dispatches a custom command or skill
        // only when the prompt itself starts with "/". The coordinator
        // consults the CURRENT catalog (rescanned per open) so a fully typed
        // known Claude command actually invokes the command; freeform `/`
        // prompts flow to the runner unchanged. This is the ONLY consumer of
        // the scan now — the suggestion UI lists Ledge's native commands.
        captureCoordinator.slashCommandCatalog = { [weak self] in
            self?.scannedCatalog ?? SlashCommandCatalog()
        }

        // Behaviors for Ledge's native commands (the coordinator decides
        // WHICH fires — LedgeCore's SubmitAction — these are the HOW).
        captureCoordinator.nativeActions = NativeCommandActions(
            openSettings: { [weak self] in self?.openSettingsFromPeek() },
            runChecks: { [weak self] in self?.runChecksFromCommand() },
            revealVault: { [weak self] in self?.revealVaultFromCommand() },
            resumeLastSession: { [weak self] in
                self?.agentRunController.resumeLastSessionInTerminal()
            },
            cancelRuns: { [weak self] in self?.agentRunController.cancelAllRuns() },
            // The existing shutdown path (applicationWillTerminate →
            // teardown) SIGTERMs any live child.
            quit: { NSApp.terminate(nil) }
        )

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
        suggestionScanTask?.cancel()
        suggestionScanTask = nil
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
            suggestionModel: suggestionModel,
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
        // Scan only on the actual transition INTO .open — a tap while
        // already open must not rescan.
        let wasAlreadyOpen = island.state == .open
        island.transition(to: .open)
        if !wasAlreadyOpen {
            scanSlashCommands()
        }
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
            scanSlashCommands()
        }
    }

    private func installHotkey() {
        KeyboardShortcuts.onKeyUp(for: .toggleCapture) { [weak self] in
            self?.toggleCapture()
        }
    }

    /// Configuration-failure peeks guide the user to Settings; the peek is
    /// dismissed so it doesn't linger behind the Settings window. Also the
    /// `/settings` native command (the island collapses first there too).
    private func openSettingsFromPeek() {
        dismissToIdle()
        onOpenSettings?()
    }

    /// `/checks`: collapse the island, then the existing showOnboarding path
    /// (the sheet lives on the Settings window, never on the notch panel).
    private func runChecksFromCommand() {
        dismissToIdle()
        onRunChecks?()
    }

    /// `/vault`: reveal the vault in Finder when the configured path is a
    /// valid vault; otherwise the same configuration-failure peek the rest of
    /// the app uses (tap → Settings). Validation reuses `Vault`'s init — the
    /// exact rules captures and runs enforce.
    private func revealVaultFromCommand() {
        guard
            let path = UserDefaults.standard.string(forKey: DefaultsKey.vaultPath),
            !path.isEmpty
        else {
            island.transition(to: .peek(.failure(
                message: "No vault set — open Settings…",
                resume: nil,
                configuration: true
            )))
            return
        }
        let root = URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: true
        )
        do {
            let vault = try Vault(root: root)
            dismissToIdle()
            NSWorkspace.shared.activateFileViewerSelecting([vault.root])
        } catch {
            island.transition(to: .peek(.failure(
                message: (error as? VaultError)?.errorDescription ?? "Vault path is invalid",
                resume: nil,
                configuration: true
            )))
        }
    }

    /// Dismissing the open island returns it to idle, which is NOT always
    /// `.collapsed`: while an agent run is live the island must keep showing
    /// the status dot (§1 "a small status dot shows a run is live"; §4
    /// `.running` == collapsed + dot). Mirrors `IslandController`'s peek
    /// expiry fallback (`.running(liveRun)` if set, else `.collapsed`).
    private func dismissToIdle() {
        // The typeahead model must never carry a dead query across opens:
        // the next transition into .open computes the open shape — and the
        // monitors' hit-test / key routing — from this model BEFORE
        // CaptureView.onAppear resets the field, so stale "/…" text would
        // briefly target a stale-grown shape and rubber-band back.
        // Discarding here matches the documented dismissal behavior (typed
        // text is discarded; onAppear still restores failed-capture input).
        suggestionModel.text = ""
        if let run = island.liveRun {
            island.transition(to: .running(run))
        } else {
            island.transition(to: .collapsed)
        }
    }

    /// Esc + click-outside monitors (§4), removed in `teardown()`.
    private func installMonitors() {
        // The ONE local key monitor: Esc dismissal (Phase 1, unchanged) plus
        // the slash-suggestion keys (↓ ↑ Tab Enter) while a list is visible.
        // Handled keys are swallowed so they don't leak elsewhere. (Local
        // monitors run synchronously on the main thread.)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handleLocalKeyDown(event)
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

    /// Returns true when the event was handled (the monitor then swallows
    /// it). Esc behavior is UNCHANGED from Phase 1 (§4: collapse). The
    /// typeahead keys act only while the island is open AND a suggestion
    /// list is visible; with no visible list every key keeps its default
    /// TextField behavior.
    ///
    /// Keyboard interaction (documented contract):
    /// * ↓ / ↑ — move the selection; WRAPS at both ends. The highlight
    ///           renders only once a selection was made — a highlighted row
    ///           always means "Enter runs this".
    /// * Tab   — completes the selected name into the field as "/name "
    ///           (trailing space, caret at end); never submits.
    /// * Enter — if the user actively moved the selection, or a REAL query
    ///           (non-empty token) has exactly one match (both render the
    ///           highlight — `shouldCompleteOnReturn`): complete, then
    ///           submit "/name " through the normal submit path (field
    ///           cleared → CaptureCoordinator), which executes it natively.
    ///           Otherwise the event passes to the TextField and the raw
    ///           text submits as before — never a row that isn't visibly
    ///           highlighted. The bare "/" never auto-runs anything.
    /// * Esc   — dismiss (Phase 1, untouched).
    /// Modified keys (⌘⌃⌥⇧) are never intercepted, and while the field's
    /// input context holds marked text (an IME composition — e.g. CJK), the
    /// list keys are never intercepted either: ↓/↑/Return then belong to the
    /// input method's candidate window and composition commit.
    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard island.state == .open else { return false }

        if event.keyCode == 53 { // Esc
            dismissToIdle()
            return true
        }

        guard suggestionModel.isListVisible,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !fieldHasMarkedText()
        else { return false }

        switch event.keyCode {
        case 125: // ↓
            suggestionModel.moveSelection(by: 1)
            return true
        case 126: // ↑
            suggestionModel.moveSelection(by: -1)
            return true
        case 48: // Tab
            suggestionModel.completeSelection()
            return true
        case 36, 76: // Return / keypad Enter
            guard suggestionModel.shouldCompleteOnReturn,
                  let command = suggestionModel.selectedCommand
            else { return false }
            let input = suggestionModel.completionText(for: command)
            // Mirrors CaptureView.submit exactly: clear the field, hand the
            // raw input to the coordinator (the normal submit path).
            suggestionModel.text = ""
            captureCoordinator.submit(input)
            return true
        default:
            return false
        }
    }

    /// True while the capture field's input context is composing marked text
    /// (an input method's inline composition). The typeahead must then keep
    /// its hands off ↓/↑/Return — they steer the IME's candidate window and
    /// commit the composition, not the list.
    private func fieldHasMarkedText() -> Bool {
        NSTextInputContext.current?.client.hasMarkedText() == true
    }

    private func handleLocalMouseDown(_ event: NSEvent) {
        guard island.state == .open else { return }
        guard event.window === window else {
            dismissToIdle()
            return
        }
        // Same numbers IslandView draws with: shape is top-centered in the
        // constant window frame (including the suggestion-list growth, so a
        // click on a row is never mistaken for click-outside).
        let size = IslandView.shapeSize(
            for: island.state,
            layout: layout,
            openSuggestionRows: suggestionModel.visibleRowCount
        )
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

    // MARK: - Slash-command scan (one per transition into .open)

    /// Fires a catalog scan for one transition into `.open`. The scan result
    /// no longer feeds the suggestion UI (the list shows Ledge's native
    /// commands) — it exists so submit-time slash restoration keeps working
    /// invisibly: a typed Claude command's prompt must reach the CLI with its
    /// leading "/" restored, or the child reads the name as prose. Called
    /// directly from the two (and only) call sites that request `.open` —
    /// tap and hotkey — NOT from the coalesced observation callback:
    /// observation re-arms asynchronously, so a rapid close→reopen can
    /// collapse into a single onChange and lose the open edge entirely,
    /// leaving that open holding a stale catalog. Event-driven (§10: zero
    /// polling, no FSEvents watchers; the catalog a given open consults is
    /// the filesystem as of that open).
    private func scanSlashCommands() {
        // Vault root from the current "vaultPath" default; nil vault →
        // user-level commands only.
        let vaultRoot: URL? = {
            guard let path = UserDefaults.standard.string(forKey: DefaultsKey.vaultPath),
                  !path.isEmpty
            else { return nil }
            return URL(
                fileURLWithPath: (path as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }()
        let userHome = FileManager.default.homeDirectoryForCurrentUser

        // Off the main actor: typical cost is milliseconds, but a giant
        // ~/.claude must never jank the open animation. §2: the scan reads
        // ONLY .claude/commands and .claude/skills under each base.
        suggestionScanTask?.cancel()
        suggestionScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let commands = SlashCommandCatalog.scan(vaultRoot: vaultRoot, userHome: userHome)
            guard !Task.isCancelled else { return } // a newer open superseded us
            await self?.applyScannedSlashCommands(commands)
        }
    }

    /// Back on the main actor: swap in the fresh catalog for submit-time
    /// slash restoration (nothing visible changes — the suggestion list is
    /// sourced from the static native-command list).
    private func applyScannedSlashCommands(_ commands: [SlashCommand]) {
        scannedCatalog = SlashCommandCatalog(commands: commands)
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
