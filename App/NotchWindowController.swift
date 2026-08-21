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
    var pickerModel: ResumePickerModel
    var changesModel: RunChangesModel
    var modelChoiceModel: ModelChoiceModel
    var openLayoutModel: OpenLayoutModel
    var runStatusModel: RunStatusModel
    var onHoverChanged: (Bool) -> Void
    var onTap: () -> Void
    var onSubmit: (String) -> Void
    var captureRestoreInput: () -> String?
    var onOpenInTerminal: (ResumeAction) -> Void
    var onCopyCommand: (ResumeAction) -> Void
    var onOpenSettings: () -> Void
    var onPickerSelect: (RunRecord) -> Void
    var onModelChoiceSelect: (RunModelChoice) -> Void

    var body: some View {
        IslandView(
            state: island.state,
            layout: layout,
            reduceMotion: reduceMotion,
            suggestionModel: suggestionModel,
            pickerModel: pickerModel,
            changesModel: changesModel,
            modelChoiceModel: modelChoiceModel,
            openLayoutModel: openLayoutModel,
            runStatusModel: runStatusModel,
            onHoverChanged: onHoverChanged,
            onIslandTap: onTap,
            onSubmit: onSubmit,
            captureRestoreInput: captureRestoreInput,
            onOpenInTerminal: onOpenInTerminal,
            onCopyCommand: onCopyCommand,
            onOpenSettings: onOpenSettings,
            onPickerSelect: onPickerSelect,
            onModelChoiceSelect: onModelChoiceSelect
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
    /// The raw pointer-inside signal, tracked from EVERY onHover edge
    /// regardless of state. The hover machinery needs it because onHover only
    /// fires on pointer enter/exit: a `.running → .peek → .running` bounce
    /// (completion peek expiring into the next queued run, a peek hovered
    /// mid-flight) clears the running-hover flag with the pointer stationary
    /// inside the shape, and only this signal can re-arm the chip then — see
    /// `syncRunningHoverToState`.
    private var pointerInsideIsland = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?

    /// Slash-command typeahead (user-requested addition beyond the MVP spec):
    /// the model the capture field binds to and the local key monitor drives.
    /// Its suggestion source is the STATIC native-command list (LedgeCore's
    /// `NativeCommand`) — nothing to scan for the UI.
    private let suggestionModel = SlashSuggestionModel()
    /// /resume picker (view-model state only — the island simply stays
    /// `.open` while it shows): rows loaded by AgentRunController from the
    /// run history, selection driven by the same local key monitor, rendered
    /// by ResumePickerList inside CaptureView. Reset on every dismiss and on
    /// every transition into `.open`, so a reopened island always starts in
    /// normal capture mode.
    private let resumePickerModel = ResumePickerModel()
    /// `/changes` pane (view-model state only — the island stays `.open` while
    /// it shows, exactly like the /resume picker): activated by the `/changes`
    /// command or by tapping a success peek, rendered by RunChangesList inside
    /// CaptureView. Reset on every dismiss and on every transition into
    /// `.open`, so a reopened island always starts in normal capture mode.
    private let runChangesModel = RunChangesModel()
    /// ⌘↩ per-run model chooser (view-model state only — the island stays
    /// `.open` while it shows, exactly like the /resume picker): activated by
    /// ⌘↩ on an agent-routed input, selection driven by the same local key
    /// monitor, rendered by ModelChoiceList inside CaptureView. Reset on
    /// every dismiss and on every transition into `.open`, like the other
    /// side-models.
    private let modelChoiceModel = ModelChoiceModel()
    /// The capture field's measured wrap growth (published by CaptureView's
    /// height preference). ONE instance feeds both IslandView's drawn shape
    /// and this controller's click-outside hit-test — the two must read the
    /// same number or clicks near the grown field's bottom edge would fall
    /// through or dead-zone. Reset on every dismiss and on every transition
    /// into `.open` (fresh field), like the picker model.
    private let openLayoutModel = OpenLayoutModel()
    /// Live-run status for the hover chip (LedgeCore), following the exact
    /// OpenLayoutModel pattern: ONE instance feeds AgentRunController's run
    /// bookkeeping (prompt + start date), this controller's hover flag AND
    /// click-outside hit-test, and IslandView's drawn shape — the widened
    /// running chip and its hit-test can never disagree. The hover flag is
    /// owned HERE: the existing hover machinery sets it (same 80 ms
    /// debounce), pointer exit and any state change away from `.running`
    /// clear it. No IslandState transition is involved — `.running → .hover`
    /// stays illegal.
    private let runStatusModel: RunStatusModel
    /// The user's Claude Code commands/skills, rescanned by
    /// `scanSlashCommands()` once per transition into `.open` — event-driven,
    /// zero polling/timers/watchers (§10). NOT shown in the suggestion list
    /// (that lists Ledge's native commands); kept solely for
    /// CaptureCoordinator's submit-time slash restoration, so a typed Claude
    /// command ("/vet …") still reaches the CLI named as a command, invisibly.
    private var scannedCatalog = SlashCommandCatalog()
    private var suggestionScanTask: Task<Void, Never>?

    /// Builds the whole notch stack in one pass. The order is load-bearing.
    ///
    /// Everything before `super.init()` runs without a usable `self`, so the
    /// first `NotchRootView` is seeded with no-op closures — a placeholder that
    /// renders but does nothing. `installRootView()` immediately after is what
    /// swaps in the real `[weak self]` handlers; delete that apparent
    /// duplication, or move it after an early return, and the island draws
    /// perfectly and ignores every click.
    ///
    /// The window is ordered front BEFORE the monitors and the hotkey go in, so
    /// nothing can ask the island to change state before there is a collapsed
    /// shape to change. `applyWindowSideEffects()` runs last because it reads
    /// the state the observation just armed.
    override init() {
        let island = IslandController()
        self.island = island
        let runStatusModel = RunStatusModel()
        self.runStatusModel = runStatusModel
        // Phase-3 wiring (§6): the runner façade adopts AgentRunSubmitting;
        // `/` prompts flow CaptureView → CaptureCoordinator → AgentRunController.
        let agentRunController = AgentRunController(island: island, runStatus: runStatusModel)
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
                pickerModel: resumePickerModel,
                changesModel: runChangesModel,
                modelChoiceModel: modelChoiceModel,
                openLayoutModel: openLayoutModel,
                runStatusModel: runStatusModel,
                onHoverChanged: { _ in },
                onTap: {},
                onSubmit: { _ in },
                captureRestoreInput: { nil },
                onOpenInTerminal: { _ in },
                onCopyCommand: { _ in },
                onOpenSettings: {},
                onPickerSelect: { _ in },
                onModelChoiceSelect: { _ in }
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

        // /resume found sessions to offer: enter picker mode — view-model
        // state only, the island stays `.open` (AgentRunController fires this
        // only after re-checking the island is still the same open session
        // /resume was typed in, via the openGeneration token, AND that no
        // run started meanwhile).
        agentRunController.onEnterResumePicker = { [weak self] records, seeded in
            guard let self, island.state == .open else { return }
            // The history load is async (and can park on a /cancel drain for
            // seconds), so a ⌘↩ chooser may have been opened meanwhile in
            // this same open session. The picker owns the island now: close
            // the chooser first, keeping the invariant that the two are
            // never active together — a lingering invisible chooser would
            // eat the picker's first Esc (Esc checks the chooser first) and
            // could never auto-close, because the picker rebinds the field
            // away from the text the chooser watches.
            modelChoiceModel.deactivate()
            runChangesModel.deactivate()
            resumePickerModel.activate(records: records, seededLastSession: seeded)
        }

        // `/changes` and a tapped success peek both land here. Same mutual
        // exclusion the picker keeps: whoever owns the island closes the
        // others first, or a lingering invisible pane eats the first Esc.
        agentRunController.onEnterChanges = { [weak self] receipt in
            guard let self else { return }
            modelChoiceModel.deactivate()
            resumePickerModel.deactivate()
            runChangesModel.activate(receipt: receipt)
        }

        // Submit-time slash restoration: CaptureRouter strips the leading
        // "/" (§5), so this puts it back when the first token exactly names a
        // catalog command. The coordinator consults the CURRENT catalog
        // (rescanned per open) so a fully typed known Claude command is asked
        // for by name; freeform `/` prompts flow to the runner unchanged. This
        // is the ONLY consumer of the scan now — the suggestion UI lists
        // Ledge's native commands.
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
                self?.agentRunController.presentResumePicker()
            },
            cancelRuns: { [weak self] in self?.agentRunController.cancelAllRuns() },
            showChanges: { [weak self] in self?.agentRunController.presentChanges() },
            undoLastRun: { [weak self] in self?.agentRunController.undoLastRun() },
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

    /// Rebuilds the entire root view. A SwiftUI view is a struct, so there is
    /// no mutating one field of a mounted one — `layout` and `reduceMotion` are
    /// stored properties of `NotchRootView`, and the only way to change them is
    /// to hand `hostingView` a whole new value.
    ///
    /// Called from the three places that each change one of those inputs:
    /// `init` (replacing the placeholder's no-op closures), a screen-geometry
    /// recompute, and a live Reduce Motion change. Every closure captures self
    /// weakly — the window retains the hosting view, which retains these
    /// closures, so a strong capture would be a cycle through AppKit and would
    /// leak the controller, its monitors, and its live runner.
    private func installRootView() {
        hostingView.rootView = NotchRootView(
            island: island,
            layout: layout,
            reduceMotion: reduceMotion,
            suggestionModel: suggestionModel,
            pickerModel: resumePickerModel,
            changesModel: runChangesModel,
            modelChoiceModel: modelChoiceModel,
            openLayoutModel: openLayoutModel,
            runStatusModel: runStatusModel,
            onHoverChanged: { [weak self] hovering in self?.hoverChanged(hovering) },
            onTap: { [weak self] in self?.islandTapped() },
            onSubmit: { [weak self] input in self?.captureCoordinator.submit(input) },
            captureRestoreInput: { [weak self] in self?.captureCoordinator.consumeRestoreInput() },
            onOpenInTerminal: { [weak self] resume in self?.agentRunController.openInTerminal(resume) },
            onCopyCommand: { [weak self] resume in self?.agentRunController.copyCommand(resume) },
            onOpenSettings: { [weak self] in self?.openSettingsFromPeek() },
            onPickerSelect: { [weak self] record in self?.resumeFromPicker(record) },
            onModelChoiceSelect: { [weak self] choice in self?.submitWithModelChoice(choice) }
        )
    }

    // MARK: - Interaction

    /// Hover with the shared 80 ms debounce; exit collapses immediately.
    ///
    /// Two hover targets share this ONE machinery (no extra monitors):
    /// - `.collapsed` → the `.hover` affordance state, exactly as before.
    /// - `.running` → the status chip: the same debounce sets the shared
    ///   `RunStatusModel.isHoveringWhileRunning` flag WITHOUT any IslandState
    ///   transition (`.running → .hover` stays illegal; the chip is
    ///   view-model state, like the /resume picker). Pointer exit clears it
    ///   immediately; so does any state change away from `.running` — and a
    ///   state change back INTO `.running` under a stationary pointer re-arms
    ///   it (`syncRunningHoverToState`, from the state observation).
    private func hoverChanged(_ hovering: Bool) {
        pointerInsideIsland = hovering
        hoverTask?.cancel()
        hoverTask = nil
        if hovering {
            switch island.state {
            case .collapsed:
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(for: IslandMotion.hoverDebounce)
                    guard let self, !Task.isCancelled else { return }
                    if island.state == .collapsed {
                        island.transition(to: .hover)
                    }
                }
            case .running:
                scheduleRunningHoverDebounce()
            default:
                break
            }
        } else {
            if runStatusModel.isHoveringWhileRunning {
                runStatusModel.isHoveringWhileRunning = false
            }
            if island.state == .hover {
                island.transition(to: .collapsed)
            }
        }
    }

    /// The ONE 80 ms debounce that flips the running-hover chip on, fired
    /// from both of its edges: a pointer-enter while `.running`
    /// (`hoverChanged`) and a transition into `.running` while the pointer
    /// already rests on the island (`syncRunningHoverToState`). Re-checks
    /// state AND the raw pointer signal after the sleep — either may have
    /// moved during the debounce.
    private func scheduleRunningHoverDebounce() {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: IslandMotion.hoverDebounce)
            guard let self, !Task.isCancelled else { return }
            if case .running = island.state, pointerInsideIsland {
                runStatusModel.isHoveringWhileRunning = true
            }
        }
    }

    /// The running-hover chip must track the state it belongs to, in BOTH
    /// directions. Away from `.running` (open, peek, collapse): drop the
    /// flag even though the pointer never left the shape. Back into
    /// `.running` with the pointer still inside: re-arm the shared debounce —
    /// a completion peek bouncing into the next queued run's `.running` (or
    /// a peek the pointer entered mid-flight) produces no onHover edge for a
    /// stationary pointer, so without this the chip would stay collapsed
    /// until the user exited and re-entered. Called from the island-state
    /// observation.
    private func syncRunningHoverToState() {
        if case .running = island.state {
            if pointerInsideIsland, !runStatusModel.isHoveringWhileRunning {
                scheduleRunningHoverDebounce()
            }
            return
        }
        if runStatusModel.isHoveringWhileRunning {
            runStatusModel.isHoveringWhileRunning = false
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
        // Tapping a success peek is the obvious "what did that just do?"
        // gesture, so it opens the receipt instead of a blank capture field.
        // The island still goes to `.open` below — the pane is open-state UI,
        // not a peek — so Esc and click-outside behave as they do everywhere.
        let openingReceipt = if case .peek(.success) = island.state {
            true
        } else {
            false
        }
        // Scan only on the actual transition INTO .open — a tap while
        // already open must not rescan. Every entry into .open starts in
        // normal capture mode (the /resume picker never survives a reopen)
        // and at the base height (a fresh field is one line; some paths out
        // of .open — e.g. submit collapsing into a peek — bypass
        // dismissToIdle, so the measurement is reset on entry as well).
        let wasAlreadyOpen = island.state == .open
        if !wasAlreadyOpen {
            resumePickerModel.deactivate()
            runChangesModel.deactivate()
            modelChoiceModel.deactivate() // open always starts without the ⌘↩ chooser
            openLayoutModel.reset()
        }
        island.transition(to: .open)
        if openingReceipt {
            agentRunController.presentChanges()
        }
        // Synchronous, not observation-driven: the panel must be ABLE to
        // become key before SwiftUI's next render fires the capture field's
        // focus request — a request landing while canBecomeKey is false is
        // silently dropped and the user has to click the field.
        applyWindowSideEffects()
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
            resumePickerModel.deactivate() // open always starts in capture mode
            runChangesModel.deactivate()
            modelChoiceModel.deactivate() // …without the ⌘↩ chooser
            openLayoutModel.reset() // …and at the base height (fresh one-line field)
            island.transition(to: .open)
            // Same synchronous key grant as islandTapped — the hotkey path
            // must have the panel key before the field's focus request lands.
            applyWindowSideEffects()
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
        // Every dismissal also leaves /resume picker mode — Esc while the
        // picker is up therefore collapses in ONE press (exit picker AND
        // collapse), and the next open starts in normal capture mode.
        resumePickerModel.deactivate()
        runChangesModel.deactivate()
        // The ⌘↩ model chooser dies with its open session too. (Esc while
        // the chooser is up never reaches here — the key monitor closes ONLY
        // the chooser first; this handles submit/click-outside/hotkey paths.)
        modelChoiceModel.deactivate()
        // The measured field height dies with its field, for the same reason
        // the typeahead text is cleared above: a stale wrap-grown measurement
        // would briefly draw (and hit-test) a too-tall open shape next time.
        openLayoutModel.reset()
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
    ///
    /// ⌘↩ (Command+Return, no other modifiers) on an input whose ENTER would
    /// start an agent run opens the per-run model chooser instead of
    /// submitting — the run can use a heavier model one time while the
    /// Settings default stays the everyday choice. "Would start an agent
    /// run" is judged by `submitActionOnReturn` — the SAME policy Enter, the
    /// target chip, and the row highlight follow — so a visibly highlighted
    /// native suggestion ("/q" → /quit) never opens the chooser. While the
    /// chooser is up:
    /// * ↓ / ↑ — move the chooser selection; wraps at both ends.
    /// * Enter — submit the CURRENT field text as an agent run with the
    ///           selected choice (the normal submit path, plus the choice).
    /// * Esc   — close ONLY the chooser; the field text and the open island
    ///           are preserved. Deliberate deviation from the resume picker's
    ///           collapse-on-Esc: the user is mid-composition here, and
    ///           throwing the typed prompt away because they peeked at the
    ///           chooser would be hostile. A second Esc dismisses as always.
    /// * Any text edit closes the chooser (CaptureView watches the field
    ///   text); typing simply continues.
    /// ⌘↩ on a non-agent route falls through untouched (nothing special).
    ///
    /// While the /resume PICKER is active its keys win over the suggestion
    /// keys (checked first; the suggestion list isn't rendered then anyway):
    /// * ↓ / ↑ — move the picker selection; wraps at both ends.
    /// * Enter — resume the highlighted session: exit picker mode, dismiss,
    ///           then the existing openInTerminal machinery. With a filter
    ///           matching nothing, Enter is swallowed and does nothing (the
    ///           filter text is never a capture).
    /// * Esc   — the normal dismiss above (dismissToIdle deactivates the
    ///           picker), so ONE press exits picker mode and collapses.
    ///
    /// Precedence: Esc · Shift+Return · ⌘↩ activation · picker keys ·
    /// chooser keys · suggestion keys. (Picker and chooser are never active
    /// together: chooser activation requires no picker, and picker
    /// activation — which lands from an ASYNC /resume history load, possibly
    /// after a ⌘↩ opened the chooser meanwhile — deactivates the chooser
    /// first (see `onEnterResumePicker`). The order mirrors the rendering
    /// precedence anyway.)
    ///
    /// Modified keys (⌘⌃⌥⇧) are never intercepted — except the ⌘↩ activation
    /// chord itself — and while the field's input context holds marked text
    /// (an IME composition — e.g. CJK), the list keys are never intercepted
    /// either: ↓/↑/Return then belong to the input method's candidate window
    /// and composition commit.
    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard island.state == .open else { return false }

        if event.keyCode == 53 { // Esc
            if modelChoiceModel.isActive {
                // Chooser only — the typed prompt and the open field survive
                // (documented deviation from the picker's collapse-on-Esc).
                modelChoiceModel.deactivate()
                return true
            }
            dismissToIdle()
            return true
        }

        // Shift+Return inserts a newline at the caret — the chat-tool
        // convention (Option+Return, the AppKit default, keeps working).
        // Normal capture mode only: a newline is meaningless in the picker's
        // filter. Going through the field editor keeps selection replacement,
        // undo, and caret position correct; during IME composition the event
        // passes through untouched. If the responder isn't the field editor
        // the event falls through and Return-submit semantics apply.
        if event.keyCode == 36 || event.keyCode == 76, // Return / keypad Enter
           event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !resumePickerModel.isActive,
           !runChangesModel.isActive,
           !fieldHasMarkedText(),
           let editor = window.firstResponder as? NSTextView
        {
            editor.insertText("\n", replacementRange: editor.selectedRange())
            return true
        }

        // ⌘↩ (Return / keypad Enter with ONLY Command) on an input whose
        // Enter would start an agent run: open the per-run model chooser.
        // Routing uses `submitActionOnReturn` — the SAME policy Enter, the
        // target chip, and the row highlight all follow — NOT bare
        // `SubmitAction.decide(text)`: for "/q" decide says .agent("q")
        // while Enter actually runs the highlighted /quit (chip: "ledge"),
        // and a chooser opened there would launch an agent run the UI never
        // advertised. Native commands and instant captures have no model to
        // choose, so ⌘↩ falls through untouched there. Never during IME
        // composition, never in picker mode; a second ⌘↩ while the chooser
        // is already up is swallowed (the chooser stays, selection
        // preserved).
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.control, .option, .shift]).isEmpty,
           !resumePickerModel.isActive,
           !runChangesModel.isActive,
           !fieldHasMarkedText()
        {
            guard case .routed(.agent) = suggestionModel.submitActionOnReturn else {
                return false // Enter wouldn't start an agent run: fall through untouched
            }
            if !modelChoiceModel.isActive {
                modelChoiceModel.activate(
                    configuredModelName: agentRunController.configuredModelName()
                )
            }
            return true
        }

        if resumePickerModel.isActive {
            guard
                event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                !fieldHasMarkedText()
            else { return false }
            switch event.keyCode {
            case 125: // ↓
                resumePickerModel.moveSelection(by: 1)
                return true
            case 126: // ↑
                resumePickerModel.moveSelection(by: -1)
                return true
            case 36, 76: // Return / keypad Enter
                if let record = resumePickerModel.selectedRecord {
                    resumeFromPicker(record)
                }
                return true // swallowed even with no selection — never a submit
            default:
                return false
            }
        }

        // `/changes` pane keys. Arrows scroll a receipt taller than the
        // window; Return is swallowed rather than submitting, because the
        // field still holds whatever was typed before `/changes` ran and
        // Enter must not fire it by surprise. Esc falls through to
        // `dismissToIdle` above, matching the picker.
        if runChangesModel.isActive {
            guard
                event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                !fieldHasMarkedText()
            else { return false }
            switch event.keyCode {
            case 125: // ↓
                runChangesModel.moveSelection(by: 1)
                return true
            case 126: // ↑
                runChangesModel.moveSelection(by: -1)
                return true
            case 36, 76: // Return / keypad Enter
                return true
            default:
                return false
            }
        }

        // ⌘↩ model chooser keys — win over the suggestion keys (the
        // suggestion list is hidden while the chooser is up).
        if modelChoiceModel.isActive {
            guard
                event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                !fieldHasMarkedText()
            else { return false }
            switch event.keyCode {
            case 125: // ↓
                modelChoiceModel.moveSelection(by: 1)
                return true
            case 126: // ↑
                modelChoiceModel.moveSelection(by: -1)
                return true
            case 36, 76: // Return / keypad Enter
                if let choice = modelChoiceModel.selectedChoice {
                    submitWithModelChoice(choice)
                }
                return true // swallowed even with no selection (defensive)
            default:
                return false
            }
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

    /// Enter on (or click of) a picker row: leave picker mode, dismiss the
    /// island (BEFORE opening — openInTerminal's write-failure peek routes
    /// through showPeek, which is dropped while `.open`), then the EXISTING
    /// §6 escape-hatch machinery resumes that exact session in Terminal —
    /// via the picker entry point, which re-checks the live-run guard last.
    private func resumeFromPicker(_ record: RunRecord) {
        guard let sessionID = record.sessionID else { return } // model filters; defensive
        let action = ResumeAction(vaultPath: record.vaultPath, sessionID: sessionID)
        dismissToIdle() // deactivates the picker and collapses
        agentRunController.openInTerminalFromPicker(action)
    }

    /// Enter on (or click of) a ⌘↩ chooser row: submit the CURRENT field
    /// text as an agent run carrying the selected per-run model choice.
    /// Mirrors CaptureView.submit exactly — chooser closed, field cleared,
    /// raw input through the coordinator's normal submit path (which routes,
    /// restores a known command's slash, and leaves `.open` synchronously).
    private func submitWithModelChoice(_ choice: RunModelChoice) {
        guard modelChoiceModel.isActive else { return } // stale click; defensive
        let input = suggestionModel.text
        modelChoiceModel.deactivate()
        suggestionModel.text = ""
        captureCoordinator.submit(input, modelChoice: choice)
    }

    /// Click-outside dismissal for clicks that reach our own windows. The shape
    /// rect is recomputed from `IslandView.shapeSize` using the SAME model
    /// values the view draws from — suggestion, picker and chooser rows, the
    /// field's wrap growth, the running hover chip. Any drift between the
    /// arguments here and the view's makes clicks near the shape's bottom edge
    /// either dismiss the island or land in a dead zone, and every new
    /// open-state element has to be threaded through here. That class of bug is
    /// exactly why `OpenIslandLayout` is shared arithmetic in LedgeCore.
    private func handleLocalMouseDown(_ event: NSEvent) {
        guard island.state == .open else { return }
        guard event.window === window else {
            dismissToIdle()
            return
        }
        // Same numbers IslandView draws with: shape is top-centered in the
        // constant window frame (including the suggestion-list or picker
        // growth AND the wrap-grown capture field, so a click on a row or
        // near the grown field's bottom edge is never mistaken for
        // click-outside).
        let size = IslandView.shapeSize(
            for: island.state,
            layout: layout,
            openSuggestionRows: suggestionModel.visibleRowCount,
            openPickerRows: resumePickerModel.isActive
                ? max(1, resumePickerModel.visibleRowCount) : 0,
            openChangesRows: runChangesModel.isActive
                ? max(1, runChangesModel.visibleRowCount) : 0,
            openChooserRows: modelChoiceModel.isActive
                ? modelChoiceModel.visibleRowCount : 0,
            openFieldExtraHeight: openLayoutModel.fieldExtraHeight,
            runningHoverStatus: runStatusModel.isHoveringWhileRunning
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
                syncRunningHoverToState()
                observeIslandState()
            }
        }
    }

    // MARK: - Slash-command scan (one per transition into .open)

    /// Fires a catalog scan for one transition into `.open`. The scan result
    /// no longer feeds the suggestion UI (the list shows Ledge's native
    /// commands) — it exists so submit-time slash restoration keeps working
    /// invisibly: a typed Claude command's prompt reaches the CLI with its
    /// leading "/" restored, naming the command rather than describing it.
    /// Called
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
        // Documented deviation from §4 ("shadow ON only when open"), by user
        // request: a borderless NSWindow with a shadow gets a ~1 px rim
        // highlight along its top edge, which shows as a seam across the
        // physical notch and betrays the illusion that the notch itself is
        // expanding. The shadow therefore stays OFF in every state.
        window.hasShadow = false
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
