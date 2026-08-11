import AppKit
import Foundation
import LedgeCore
import os

/// Phase-3 App-layer façade over `ClaudeRunner` (§6). Adopts
/// `AgentRunSubmitting` for CaptureCoordinator; owns one runner per
/// (vault, binary) pair — recreated when the vault default changes (cheap
/// check on submit); consumes `RunnerEvent`s into island transitions and
/// peeks; persists session IDs per vault; and services the failure-peek
/// escape hatch (resume script + pasteboard).
///
/// Two discipline rules govern every transition here:
/// - Enter leaves `.open` synchronously (§5) — the user is never left waiting
///   at the notch while the binary resolves or the runner actor responds.
/// - Runner-driven (async) transitions never yank `.open` out from under the
///   user: a completion peek is dropped while the capture field is up (the
///   bookkeeping still happens), and a queued run starting behind a peek or
///   the open field only updates `liveRun` via `setLiveRun` so the current UI
///   survives (peek expiry then falls back to `.running(newHandle)`).
///
/// Nothing here activates Ledge or makes the panel key: peeks overlay the
/// user's work without stealing focus (§4), and "Open in Terminal" hands the
/// script to NSWorkspace, which activates Terminal — not Ledge.
@MainActor
final class AgentRunController: AgentRunSubmitting {
    private let island: IslandController
    /// Live-run status for the hover chip (LedgeCore, shared with the window
    /// controller and IslandView). This controller owns the RUN bookkeeping —
    /// prompt + start date are set on the same paths that set `liveHandle` /
    /// `island.liveRun` and cleared on every path that clears them; the hover
    /// flag inside the model belongs to NotchWindowController.
    private let runStatus: RunStatusModel
    private let defaults: UserDefaults
    /// One resolver per launch so the login-shell fallback (`/bin/zsh -lc
    /// 'command -v claude'`) runs at most once (§6). Sendable — `resolve()`
    /// is always called OFF the main actor (the login shell must never block
    /// the UI). Rebuilt (cache and all) only when the Settings override
    /// ("claudeBinaryPath") changes — see `currentResolver()`.
    private var resolver: ClaudeBinaryResolver
    /// The override the current `resolver` was built with (nil = none).
    private var resolverOverridePath: String?
    private var runner: ClaudeRunner?
    private var runnerVaultPath: String?
    private var runnerBinaryPath: String?
    private var runnerModel: String?
    private var runnerEffort: String?
    private var eventsTask: Task<Void, Never>?
    /// Drains a retired runner (vault/binary changed): terminateAll SIGTERMs,
    /// escalates to SIGKILL, and returns only once the old child is dead.
    /// Every enqueue on the replacement awaits this first — §2.4: one live
    /// run per vault, so the old and new child must never overlap.
    private var retirementDrain: Task<Void, Never>?
    /// Retired runners whose drain has not finished — their child may still be
    /// alive. `shutdown()` must SIGTERM these too: the detached drain task
    /// that owns their SIGTERM→SIGKILL escalation dies with the process, so
    /// without this a retired runner's child could silently survive quit (§6).
    private var retiredRunners: [ClaudeRunner] = []
    /// Serializes submissions: each Enter's async pipeline (binary resolve →
    /// retirement-drain wait → enqueue) chains onto the previous one, so
    /// runner enqueue order always equals Enter order. Two submissions parked
    /// on the same retirement drain would otherwise resume in unspecified
    /// order and could enqueue inverted (flow D FIFO).
    private var submissionChain: Task<Void, Never>?
    /// Mirrors the runner's pending-queue depth (from queueChanged events) so
    /// completion handling knows whether another run follows immediately.
    private var queueDepth = 0
    /// The handle of the run the runner reported live (from runStarted /
    /// completion events). Distinct from `island.liveRun`, which may briefly
    /// hold a provisional handle between Enter and the runner's confirmation.
    private var liveHandle: RunHandle?
    /// Effective `--model` value per accepted run (keyed by RunHandle.id) —
    /// the completion path writes it into the history record. Absent key =
    /// no --model flag (`.cliDefault`, or nothing configured), recorded as
    /// nil. Populated when the runner accepts an enqueue, drained on
    /// completion; cleared wholesale on /cancel and runner retirement (those
    /// runs never reach the completion path).
    private var effectiveModelByRunID: [UUID: String] = [:]
    /// Reports a submission that was rejected before it ever ran (no vault,
    /// bad vault, no binary, queue full) so CaptureCoordinator can preserve
    /// the typed input — text is never lost to a failure peek.
    var onSubmissionRejected: ((_ prompt: String) -> Void)?
    /// /resume found sessions to offer: the window controller (which owns the
    /// picker view-model) activates picker mode with these rows. Fired only
    /// while the island is still `.open` on the controller's side.
    /// `seededLastSession` is true when the single row is the stored
    /// per-vault lastSessionID fallback — the UI then renders it neutrally
    /// (no time, no outcome glyph) because Ledge stores only the ID, not
    /// when the session ran or how it ended.
    var onEnterResumePicker: ((_ records: [RunRecord], _ seededLastSession: Bool) -> Void)?
    /// Local run history (JSONL in Ledge's own Application Support — §2:
    /// never the vault, never ~/.claude). Written on completion events and
    /// read by /resume, both OFF the main actor; best-effort throughout.
    private let historyStore: RunHistoryStore
    /// Serializes ALL history I/O: every append (completion AND /cancel)
    /// chains onto the previous one, so file order provably equals
    /// completion order — which is exactly what `recentRuns`' newest-first-
    /// by-file-order relies on — and `compactIfNeeded` (called from append)
    /// can never race another in-flight append and silently discard it. The
    /// /resume read awaits this chain too, so a read can never overtake the
    /// append of a completion whose peek the user just saw.
    private var historyChain: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.ledge", category: "runner")

    init(
        island: IslandController,
        runStatus: RunStatusModel = RunStatusModel(),
        defaults: UserDefaults = .standard,
        historyStore: RunHistoryStore? = nil
    ) {
        self.island = island
        self.runStatus = runStatus
        self.defaults = defaults
        self.historyStore = historyStore ?? RunHistoryStore(fileURL: Self.defaultHistoryURL())
        let override = Self.storedOverride(in: defaults)
        resolver = ClaudeBinaryResolver(overridePath: override)
        resolverOverridePath = override
    }

    /// appSupport/Ledge/run-history.jsonl — the App layer supplies the URL;
    /// LedgeCore never hardcodes it. The `?? home` fallback can effectively
    /// never fire (macOS always reports an Application Support directory)
    /// but keeps this force-unwrap-free.
    private static func defaultHistoryURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Ledge", isDirectory: true)
            .appendingPathComponent("run-history.jsonl", isDirectory: false)
    }

    /// The §7 Settings binary override; empty string = unset.
    private static func storedOverride(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: DefaultsKey.claudeBinaryPath)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The §7-adjacent model/effort overrides for agent runs, snapshotted per
    /// Enter (same enqueue-time semantics as the resume ID). Model: empty =
    /// the user's own Claude Code default. Effort: absent = Ledge's default
    /// "high"; the `effortCLIDefault` sentinel = pass no flag.
    private func storedModelOverride() -> String? {
        ClaudeRunner.sanitizeOverride(defaults.string(forKey: DefaultsKey.claudeModel))
    }

    private func storedEffort() -> String? {
        guard let raw = defaults.string(forKey: DefaultsKey.claudeEffort) else { return "high" }
        if raw == DefaultsKey.effortCLIDefault {
            return nil
        }
        return ClaudeRunner.sanitizeOverride(raw) ?? "high"
    }

    /// Returns the resolver matching the CURRENT Settings override, rebuilding
    /// it (fresh login-shell cache) only when the override changed.
    private func currentResolver() -> ClaudeBinaryResolver {
        let override = Self.storedOverride(in: defaults)
        if override != resolverOverridePath {
            resolver = ClaudeBinaryResolver(overridePath: override)
            resolverOverridePath = override
        }
        return resolver
    }

    /// The Settings model name the ⌘↩ chooser's "Configured default" row
    /// shows — the same sanitized read every enqueue snapshots; nil = none
    /// set (the row's subtitle then says so).
    func configuredModelName() -> String? {
        storedModelOverride()
    }

    // MARK: - AgentRunSubmitting

    func submitAgentRun(prompt: String, modelChoice: RunModelChoice) {
        guard
            let configuredPath = defaults.string(forKey: DefaultsKey.vaultPath),
            !configuredPath.isEmpty
        else {
            reject(prompt: prompt, message: "No vault set — open Settings…", configuration: true)
            return
        }
        let vaultPath = (configuredPath as NSString).expandingTildeInPath
        let vault: Vault
        do {
            vault = try Vault(root: URL(fileURLWithPath: vaultPath, isDirectory: true))
        } catch {
            reject(
                prompt: prompt,
                message: (error as? VaultError)?.errorDescription ?? "Vault path is invalid",
                configuration: true
            )
            return
        }

        // §7 "continue last": resume only when the toggle is on AND the stored
        // per-vault ID passes the ResumeScriptWriter guard (ResumePolicy —
        // LedgeCore, tested). An invalid stored value is treated as nil and
        // cleared so it is never considered again.
        //
        // Deliberately resolved AT ENTER TIME (§7 binding decision:
        // `submitAgentRun` passes the resume ID): the chosen session rides
        // with the Enter press into the queue. A prompt queued behind a live
        // run therefore resumes the session as it stood when the user typed
        // it — it does NOT pick up the still-running run's session, and
        // flipping the toggle affects only submissions made afterwards.
        let sessionKey = DefaultsKey.lastSessionID(vaultPath: vaultPath)
        let resumeChoice = ResumePolicy.pickResumeSessionID(
            enabled: defaults.bool(forKey: DefaultsKey.continueLastSession),
            stored: defaults.string(forKey: sessionKey)
        )
        if resumeChoice.shouldClearStored {
            logger.error("stored session ID invalid — clearing \(sessionKey, privacy: .public)")
            defaults.removeObject(forKey: sessionKey)
        }

        // Queue-bound is decided NOW, from Enter-time state — a confirmed
        // live run (`liveHandle`), an earlier Enter's provisional handle
        // still in its pre-enqueue window (`island.liveRun`, set
        // synchronously per Enter, which `liveHandle` lags behind by binary
        // resolution — seconds on first launch), or queued prompts already
        // waiting. It picks the start peek's wording and gates the hover
        // chip's provisional bookkeeping below; checked BEFORE the
        // `.running` transition, which overwrites `island.liveRun`.
        let queueBound = liveHandle != nil || island.liveRun != nil || queueDepth > 0

        // §5: Enter leaves `.open` synchronously — the running dot shows
        // immediately. If a run is already live its handle keeps the dot;
        // otherwise a provisional handle stands in until the runner confirms
        // (`.started` replaces it; a rejection clears it again). An EARLIER
        // Enter's provisional (`island.liveRun`) is reused, never replaced:
        // that run goes first, and minting a fresh handle here would flip the
        // bookkeeping to this queue-bound prompt.
        island.transition(to: .running(liveHandle ?? island.liveRun ?? RunHandle(prompt: prompt)))
        if !queueBound {
            // The hover chip's bookkeeping starts NOW: Enter is the honest
            // wall-clock zero the user cares about (the runner's runStarted
            // confirmation lags by binary resolution). A queue-bound
            // submission must NOT touch the model: it keeps describing the
            // run that is (or is about to be) live — including a previous
            // Enter still awaiting confirmation, whose prompt and zero point
            // a second Enter would otherwise overwrite.
            runStatus.recordRunStart(prompt: prompt)
        }
        // Start acknowledgment: a 2.5 s info peek right on top of the
        // `.running` transition above — which set `island.liveRun`, so peek
        // expiry falls back to `.running` and restores the dot. Any
        // follow-up peek replaces it naturally (peek → peek is legal): the
        // runner's "Queued #n" for a queued submission, or a rejection /
        // failure peek. runStarted deliberately fires NO second start peek —
        // this one already acknowledged the Enter. A queue-bound submission
        // says "queued" (not "working…") from the start: the runner's
        // positioned "Queued #n" can lag the whole pipeline (a retirement
        // drain waits for the old child to die), well past this banner's
        // 2.5 s, so the Enter-time wording must already be truthful.
        island.transition(to: .peek(.info(message: Self.startPeekMessage(
            for: prompt, queueBound: queueBound
        ))))

        let resolver = currentResolver()
        let model = storedModelOverride()
        let effort = storedEffort()
        // The run's effective --model value (nil = no flag), resolved from
        // the SAME Enter-time snapshot the runner's Configuration gets — so
        // what history records is exactly what the spawn site puts in argv.
        let effectiveModel = RunModelChoice.effectiveModel(
            choice: modelChoice, configured: model
        )
        let previousSubmission = submissionChain
        submissionChain = Task { [weak self] in
            // FIFO discipline: this Enter's pipeline starts only after the
            // previous Enter's pipeline reached its enqueue (or bailed).
            await previousSubmission?.value
            // Off the main actor: the login-shell fallback can take seconds.
            let binaryPath = await Task.detached { resolver.resolve() }.value
            guard let self else { return }
            guard let binaryPath else {
                rejectAsync(
                    prompt: prompt,
                    message: "Claude Code not found — open Settings…",
                    configuration: true
                )
                return
            }
            let runner = ensureRunner(
                vault: vault,
                vaultPath: vaultPath,
                binaryPath: binaryPath,
                model: model,
                effort: effort
            )
            // Never enqueue while a retired runner's child may still be alive.
            await retirementDrain?.value
            let enqueued = await runner.enqueue(
                prompt: prompt,
                resumeSessionID: resumeChoice.sessionID,
                modelChoice: modelChoice
            )
            handle(enqueued: enqueued, prompt: prompt, effectiveModel: effectiveModel)
        }
    }

    // MARK: - Escape hatch (failure peek buttons)

    /// Writes /tmp/ledge-resume-<uuid>.command and opens it — Terminal runs it
    /// through the user's login shell, resuming the exact session (§6).
    func openInTerminal(_ resume: ResumeAction) {
        do {
            let script = try ResumeScriptWriter.writeResumeScript(
                vaultPath: resume.vaultPath,
                sessionID: resume.sessionID
            )
            NSWorkspace.shared.open(script)
        } catch {
            logger.error("resume script failed: \(error.localizedDescription, privacy: .public)")
            showPeek(.failure(message: "Couldn't write the resume script", resume: nil))
        }
    }

    func copyCommand(_ resume: ResumeAction) {
        guard let line = try? ResumeScriptWriter.commandLine(
            vaultPath: resume.vaultPath,
            sessionID: resume.sessionID
        ) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(line, forType: .string)
    }

    // MARK: - Native commands (/resume, /cancel)

    /// The `/resume` native command: offers a picker of recent recorded
    /// sessions for the current vault inside the open island; selecting one
    /// opens that exact session in Terminal via the §6 escape-hatch machinery
    /// (`openInTerminal`). The island STAYS `.open` while the picker is up —
    /// picker mode is view-model state owned by the window controller
    /// (`ResumePickerModel`), reached through `onEnterResumePicker`;
    /// IslandState is untouched.
    ///
    /// The history is read OFF the main actor (like the catalog scan). When
    /// it yields no resumable session, the stored per-vault lastSessionID
    /// default seeds a single "last session" row — same `ResumePolicy` guard
    /// as "continue last", with `enabled` hardwired true: typing /resume IS
    /// the explicit ask. An invalid stored ID is cleared (never considered
    /// again). Nothing at all → info peek.
    func presentResumePicker() {
        // §2.4 discipline (spirit): /resume must not put a second `claude` to
        // work in the vault while a headless run is live, queued, or still in
        // its pre-enqueue pipeline (`island.liveRun` is set synchronously on
        // Enter, before the runner bookkeeping catches up) — the Terminal
        // process would edit the same vault the child is editing, possibly
        // resuming the very session the live run holds.
        guard resumeRunGuardHolds else {
            island.transition(to: .peek(.info(message: "Run in progress — /cancel first")))
            return
        }
        guard
            let configuredPath = defaults.string(forKey: DefaultsKey.vaultPath),
            !configuredPath.isEmpty
        else {
            island.transition(to: .peek(.failure(
                message: "No vault set — open Settings…", resume: nil, configuration: true
            )))
            return
        }
        let vaultPath = (configuredPath as NSString).expandingTildeInPath
        let store = historyStore
        // Captured NOW, checked again when the load lands: the picker may
        // only activate in the SAME open session /resume was typed in.
        let generation = island.openGeneration
        Task { [weak self] in
            // /cancel (and retirement) clear the run bookkeeping BEFORE the
            // SIGTERMed child is actually dead — wait for the drain exactly
            // like submit's enqueue does (§2.4), so a picker-initiated
            // Terminal `claude` can never overlap the dying child in the
            // vault. Bonus: the drain appends the cancelled run's record, so
            // a /resume right after /cancel offers that very session.
            await self?.retirementDrain?.value
            guard let self else { return }
            let chain = historyChain
            // Off the main actor: synchronous file I/O, like the catalog
            // scan. Awaiting the chain first means the read can never
            // overtake a still-pending completion append.
            let runs = await Task.detached(priority: .userInitiated) {
                await chain?.value
                return store.recentRuns(vaultPath: vaultPath)
            }.value
            presentLoadedResumePicker(runs: runs, vaultPath: vaultPath, generation: generation)
        }
    }

    /// The §2.4-spirit condition under which /resume may proceed: nothing
    /// live, nothing queued, nothing in its pre-enqueue pipeline. Checked at
    /// command time AND re-checked when the async history load lands (plus
    /// `retiredRunners.isEmpty` there — a retired child may still be dying).
    private var resumeRunGuardHolds: Bool {
        liveHandle == nil && queueDepth == 0 && island.liveRun == nil
    }

    /// Back on the main actor with the loaded history: decide between picker,
    /// seeded last-session row, and the empty-state peek.
    private func presentLoadedResumePicker(
        runs: [RunRecord],
        vaultPath: String,
        generation: Int
    ) {
        // Staleness re-checks — the load was async and the world may have
        // moved:
        // - The island must not only still be `.open`, it must be the SAME
        //   open session /resume was typed in: a dismiss→reopen (or
        //   submit→reopen) during the load bumps `openGeneration`, and a
        //   picker popping into a fresh capture session would silently turn
        //   the user's next Enter into a Terminal resume.
        guard island.state == .open, island.openGeneration == generation else { return }
        // - The run guard must still hold: a run submitted during the load
        //   wins over the picker (§2.4 spirit — never a Terminal `claude`
        //   beside a headless child in the same vault), and a freshly
        //   retired runner's child may still be alive. Dropped silently: the
        //   reopened field may hold the user's typing, which a peek would
        //   destroy.
        guard resumeRunGuardHolds, retiredRunners.isEmpty else {
            logger.info("/resume dropped: a run started or was retired during the history load")
            return
        }
        var rows = ResumePickerModel.resumableRecords(runs)
        var seededLastSession = false
        if rows.isEmpty {
            // Pre-history fallback: the stored per-vault last session ID.
            let sessionKey = DefaultsKey.lastSessionID(vaultPath: vaultPath)
            let choice = ResumePolicy.pickResumeSessionID(
                enabled: true,
                stored: defaults.string(forKey: sessionKey)
            )
            if choice.shouldClearStored {
                logger.error("stored session ID invalid — clearing \(sessionKey, privacy: .public)")
                defaults.removeObject(forKey: sessionKey)
            }
            if let sessionID = choice.sessionID {
                // UserDefaults stores ONLY the ID — when this session ran and
                // how it ended are unknown (it may be hours old, persisted
                // from a failed run). `date`/`outcome` are inert placeholders
                // the UI never shows: the `seededLastSession` flag makes the
                // row render neutrally (no time, no glyph).
                seededLastSession = true
                rows = [RunRecord(
                    id: UUID(),
                    date: Date(),
                    vaultPath: vaultPath,
                    prompt: "last session",
                    sessionID: sessionID,
                    outcome: .success,
                    editedFiles: [],
                    durationMS: nil,
                    resultExcerpt: nil,
                    stderrTail: []
                )]
            }
        }
        guard !rows.isEmpty else {
            island.transition(to: .peek(.info(message: "No sessions recorded yet")))
            return
        }
        onEnterResumePicker?(rows, seededLastSession)
    }

    /// Picker-row resume (Enter or click): the same §6 escape hatch,
    /// re-guarded. Between picker activation and Enter no run can normally
    /// start (Enter is swallowed by the key monitor while the picker is up,
    /// and activation required an idle runner), so this is cheap belt and
    /// braces: never hand Terminal a `claude --resume` into the vault while
    /// a headless child lives or a retired one is still dying.
    func openInTerminalFromPicker(_ resume: ResumeAction) {
        guard resumeRunGuardHolds, retiredRunners.isEmpty else {
            showPeek(.info(message: "Run in progress — /cancel first"))
            return
        }
        openInTerminal(resume)
    }

    /// The `/cancel` native command: terminate the live child and drop the
    /// whole queue. Reuses the retirement machinery verbatim — a full-stop
    /// retire of the current runner (terminateAll SIGTERMs, escalates to
    /// SIGKILL, returns once the child is dead); the next submit lazily
    /// creates a fresh runner, and its enqueue awaits `retirementDrain`
    /// first, so a /submit racing /cancel can never spawn while the
    /// cancelled child still lives (§2.4 one-run-per-vault, same discipline
    /// as a vault/binary change). Unlike retirement, the dropped queued
    /// prompts are NOT handed back — the user explicitly asked to cancel
    /// them — and the "Cancelled" peek fires only once the child is dead.
    ///
    /// Two lag disciplines make /cancel honest under races:
    /// - The no-op guard consults `island.liveRun` (set synchronously on
    ///   Enter) as well as the runner bookkeeping, which lags by the whole
    ///   async pipeline (binary resolution can take seconds) and by the event
    ///   stream (queueChanged(0) precedes the next runStarted). A visible
    ///   running dot therefore never coexists with a "No run to cancel" peek.
    /// - The cancellation itself is a LINK ON THE SUBMISSION CHAIN: it runs
    ///   only after every prior Enter's pipeline finished its enqueue, so a
    ///   submission in its pre-enqueue window when /cancel arrives is
    ///   enqueued first and then killed here — never silently raced (stale
    ///   "Ledge is quitting" rejections, post-cancel "Queued #1" peeks, or a
    ///   showRunning re-setting bookkeeping the cancel just cleared). A
    ///   submission entered AFTER /cancel chains behind it and spawns on a
    ///   fresh runner once the cancelled child is dead.
    func cancelAllRuns() {
        guard liveHandle != nil || queueDepth > 0 || island.liveRun != nil else {
            island.transition(to: .peek(.info(message: "No run to cancel")))
            return
        }
        logger.info("/cancel — terminating live run and dropping the queue")
        // Enter leaves `.open` synchronously (§5): drop the dot and collapse
        // now; the chained cancellation confirms once the child is dead.
        island.clearLiveRun()
        runStatus.clear()
        dismissToIdle()
        let previousSubmission = submissionChain
        submissionChain = Task { [weak self] in
            await previousSubmission?.value
            self?.performCancellation()
        }
    }

    /// The chained /cancel body (main actor, after all prior submission
    /// pipelines enqueued): retire the current runner through the exact
    /// retirement machinery. A nil runner means the pipeline this /cancel
    /// chained behind never spawned anything (it was rejected — its failure
    /// peek already explains why), so there is nothing to kill and no peek
    /// to show.
    ///
    /// History: the SIGTERMed child's `runCompleted` event IS still emitted
    /// by the runner's worker loop (SIGTERM → termination handler → a
    /// `.failure(.nonZeroExit)` completion), but this method cancels
    /// `eventsTask` and nils `runner` first, so the App layer never observes
    /// it (the identity guard would drop it even if the loop resumed once
    /// more). The cancelled run is therefore recorded HERE: prompt and vault
    /// are captured before the bookkeeping clears, and the session ID is read
    /// off the retired runner's parser (`lastObservedSessionID`) once the
    /// child is dead — best-effort, like all history.
    private func performCancellation() {
        guard let previous = runner else { return }
        let cancelledPrompt = liveHandle?.prompt
        let cancelledVaultPath = runnerVaultPath
        // The cancelled run's effective model, read before the bookkeeping
        // clears (the whole map dies with the runner — its queued runs never
        // reach the completion path).
        let cancelledModel = liveHandle.flatMap { effectiveModelByRunID[$0.id] }
        eventsTask?.cancel()
        eventsTask = nil
        island.clearLiveRun()
        runStatus.clear()
        liveHandle = nil
        queueDepth = 0
        effectiveModelByRunID = [:]
        runner = nil
        runnerVaultPath = nil
        runnerBinaryPath = nil
        runnerModel = nil
        runnerEffort = nil
        retiredRunners.append(previous)
        let previousDrain = retirementDrain
        retirementDrain = Task.detached { [weak self] in
            await previousDrain?.value
            // Returns once the child has exited; dropped prompts discarded
            // deliberately (cancellation, not retirement).
            _ = await previous.terminateAll()
            if let prompt = cancelledPrompt, let vaultPath = cancelledVaultPath {
                let sessionID = await previous.lastObservedSessionID
                let record = RunRecord(
                    id: UUID(),
                    date: Date(),
                    vaultPath: vaultPath,
                    prompt: prompt,
                    sessionID: sessionID,
                    model: cancelledModel,
                    outcome: .cancelled,
                    editedFiles: [],
                    durationMS: nil,
                    resultExcerpt: nil,
                    stderrTail: []
                )
                // Chained like every other append (main-actor hop): the
                // cancelled record can never race — or be clobbered by the
                // compaction inside — a completion append.
                await self?.appendHistory(record)
            }
            await self?.finishCancellation(of: previous)
        }
    }

    /// Cancellation epilogue (main actor, from the drain task): forget the
    /// dead runner and confirm. showPeek's `.open` guard applies — if the
    /// user reopened the field meanwhile, the banner is dropped, as with
    /// every other runner-driven peek.
    private func finishCancellation(of retired: ClaudeRunner) {
        retiredRunners.removeAll { $0 === retired }
        showPeek(.info(message: "Cancelled"))
    }

    /// Mirrors `NotchWindowController.dismissToIdle`: idle is
    /// `.running(liveRun)` while an agent run is live, else `.collapsed`.
    private func dismissToIdle() {
        if let run = island.liveRun {
            island.transition(to: .running(run))
        } else {
            island.transition(to: .collapsed)
        }
    }

    // MARK: - Quit

    /// App quit (§6): SIGTERM the live child. `terminateNow()` is nonisolated
    /// and synchronous — the signal is sent before this returns, with no
    /// semaphore and no dependence on executor scheduling during termination.
    /// It also marks the runner as shutting down, so nothing new can spawn in
    /// the window before process exit.
    ///
    /// Retired runners are signaled too: their SIGTERM→SIGKILL escalation
    /// lives in a detached drain task that dies with the process, so a
    /// vault/binary change followed by a quick quit would otherwise leave the
    /// old child alive and editing the old vault. `terminateNow()` is
    /// idempotent — overlapping an in-flight `terminateAll()` is harmless.
    func shutdown() {
        eventsTask?.cancel()
        eventsTask = nil
        runner?.terminateNow()
        for retired in retiredRunners {
            retired.terminateNow()
        }
    }

    // MARK: - Runner lifetime & events

    private func ensureRunner(
        vault: Vault,
        vaultPath: String,
        binaryPath: String,
        model: String?,
        effort: String?
    ) -> ClaudeRunner {
        if let runner, runnerVaultPath == vaultPath, runnerBinaryPath == binaryPath,
           runnerModel == model, runnerEffort == effort
        {
            return runner
        }
        if let previous = runner {
            logger.info("vault, binary, model, or effort changed — retiring previous runner")
            eventsTask?.cancel()
            // The retired runner's events are never handled (the identity
            // guard below drops any already-in-flight one), so clear the
            // live-run bookkeeping now — otherwise dismiss/peek expiry would
            // keep restoring `.running(staleHandle)` forever.
            island.clearLiveRun()
            runStatus.clear()
            liveHandle = nil
            queueDepth = 0
            // The retired runner's runs never reach the completion path; its
            // effective-model bookkeeping dies with it.
            effectiveModelByRunID = [:]
            retiredRunners.append(previous)
            let previousDrain = retirementDrain
            retirementDrain = Task.detached { [weak self] in
                await previousDrain?.value
                // Waits until the child is dead; returns the queued prompts
                // it dropped so they are not lost silently.
                let dropped = await previous.terminateAll()
                await self?.finishRetirement(of: previous, droppedPrompts: dropped)
            }
        }
        let created = ClaudeRunner(configuration: ClaudeRunner.Configuration(
            binaryURL: URL(fileURLWithPath: binaryPath),
            vault: vault,
            model: model,
            effort: effort
        ))
        runner = created
        runnerVaultPath = vaultPath
        runnerBinaryPath = binaryPath
        runnerModel = model
        runnerEffort = effort
        queueDepth = 0
        eventsTask = Task { [weak self] in
            for await event in created.events {
                // Identity guard: cancel() cannot stop an event that already
                // resumed the loop before the runner was swapped. Handling it
                // anyway would apply a retired runner's completion to the NEW
                // vault's state — e.g. persist vault A's session ID under
                // "lastSessionID:<vault B>", the exact cross-vault leak the
                // per-vault keying exists to prevent.
                guard let self, runner === created else { return }
                handle(event: event)
            }
        }
        return created
    }

    /// Retirement epilogue (main actor, called from the drain task): forget
    /// the dead runner and surface the queued prompts its `terminateAll`
    /// dropped. The user saw those acknowledged with a "Queued #n" peek, so
    /// they must not vanish silently — each is handed back through
    /// `onSubmissionRejected` (the single-slot restore keeps the LAST one in
    /// the field) and one info peek reports the drop.
    private func finishRetirement(of retired: ClaudeRunner, droppedPrompts: [String]) {
        retiredRunners.removeAll { $0 === retired }
        guard !droppedPrompts.isEmpty else { return }
        for prompt in droppedPrompts {
            onSubmissionRejected?(prompt)
        }
        let count = droppedPrompts.count
        showPeek(.info(message: count == 1
                ? "1 queued prompt dropped — vault or binary changed"
                : "\(count) queued prompts dropped — vault or binary changed"))
    }

    private func handle(enqueued: Enqueued, prompt: String, effectiveModel: String?) {
        switch enqueued {
        case let .started(handle):
            if let effectiveModel {
                effectiveModelByRunID[handle.id] = effectiveModel
            }
            showRunning(handle)
        case let .queued(handle, position):
            if let effectiveModel {
                effectiveModelByRunID[handle.id] = effectiveModel
            }
            showPeek(.queued(position: position))
        case let .rejected(reason):
            rejectAsync(
                prompt: prompt,
                message: Self.message(for: reason),
                configuration: Self.isConfiguration(reason)
            )
        }
    }

    private func handle(event: RunnerEvent) {
        switch event {
        case let .runStarted(handle):
            showRunning(handle)
        case let .queueChanged(depth):
            queueDepth = depth
        case let .runCompleted(completion):
            handle(completion: completion)
        }
    }

    private func handle(completion: RunCompletion) {
        recordHistory(for: completion)
        liveHandle = nil
        // The finished run's hover-chip status dies with it; when depth > 0
        // the next run's runStarted repopulates the model immediately.
        runStatus.clear()
        // Another queued run starts immediately when depth > 0; only a fully
        // idle runner clears the live-run dot (peek expiry then falls back to
        // `.collapsed` instead of `.running`).
        if queueDepth == 0 {
            island.clearLiveRun()
        }
        switch completion.outcome {
        case let .success(summary):
            persistSessionID(summary.sessionID)
            showPeek(.success(
                filesEdited: summary.editedFiles.count,
                duration: Double(summary.durationMS ?? 0) / 1000
            ))
        case let .failure(failure):
            persistSessionID(failure.sessionID)
            let resume = failure.sessionID.flatMap { sessionID -> ResumeAction? in
                guard let vaultPath = runnerVaultPath else { return nil }
                return ResumeAction(vaultPath: vaultPath, sessionID: sessionID)
            }
            showPeek(.failure(message: Self.message(for: failure), resume: resume))
        }
    }

    // MARK: - Run history (best-effort, §2: Ledge's own App Support only)

    /// Builds and appends the history record for a completed run. Failures
    /// are logged (category "runner"), never surfaced — the history must
    /// never turn a successful run into a failure peek.
    private func recordHistory(for completion: RunCompletion) {
        // Drained unconditionally (even if the vault guard below bails): the
        // run is over either way. Absent key = no --model flag → nil.
        let model = effectiveModelByRunID.removeValue(forKey: completion.handle.id)
        guard let vaultPath = runnerVaultPath else { return }
        let record = switch completion.outcome {
        case let .success(summary):
            RunRecord(
                id: UUID(),
                date: Date(),
                vaultPath: vaultPath,
                prompt: completion.handle.prompt,
                sessionID: summary.sessionID,
                model: model,
                outcome: .success,
                editedFiles: summary.editedFiles,
                durationMS: summary.durationMS,
                resultExcerpt: summary.resultText, // init truncates to 500
                stderrTail: []
            )
        case let .failure(failure):
            RunRecord(
                id: UUID(),
                date: Date(),
                vaultPath: vaultPath,
                prompt: completion.handle.prompt,
                sessionID: failure.sessionID,
                model: model,
                outcome: .failure(reason: Self.headline(for: failure)),
                editedFiles: [],
                durationMS: nil,
                resultExcerpt: nil,
                stderrTail: failure.stderrTail
            )
        }
        appendHistory(record)
    }

    /// The ONE way history is written: a link on `historyChain`, running OFF
    /// the main actor (like the catalog scan) but strictly after every
    /// earlier append. Called on the main actor in completion order, so file
    /// order equals completion order — see `historyChain`.
    private func appendHistory(_ record: RunRecord) {
        let store = historyStore
        let log = logger
        let previous = historyChain
        historyChain = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try store.append(record)
            } catch {
                log.error(
                    "run-history append failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Guarded transitions

    /// A run started. Transition to `.running` unless the island is showing
    /// something that must survive: the previous run's completion peek (§4:
    /// banners show for their full 2.5 s) or the open capture field (whose
    /// typed text a transition would destroy). In those cases only the
    /// live-run bookkeeping updates; peek expiry / dismiss then falls back to
    /// `.running(handle)`.
    private func showRunning(_ handle: RunHandle) {
        liveHandle = handle
        // Hover-chip bookkeeping rides along with the live-run handle. For
        // the run just submitted (same prompt) the model keeps the Enter-time
        // start date; a queued run starting now restarts the clock.
        runStatus.recordRunStart(prompt: handle.prompt)
        switch island.state {
        case .open, .peek:
            island.setLiveRun(handle)
        default:
            island.transition(to: .running(handle))
        }
    }

    /// Runner-driven peeks never yank the open capture field out from under
    /// the user — while `.open`, the banner is dropped (all bookkeeping has
    /// already happened; the session ID is persisted for Phase 4's
    /// "continue last session").
    private func showPeek(_ content: PeekContent) {
        guard island.state != .open else { return }
        island.transition(to: .peek(content))
    }

    /// Synchronous (still-on-Enter) rejection: the user just pressed Enter,
    /// so replacing `.open` with the failure peek IS the feedback — and the
    /// typed input is preserved via `onSubmissionRejected`. `configuration`
    /// marks setup problems: the peek then offers "Open Settings…" (§7).
    private func reject(prompt: String, message: String, configuration: Bool = false) {
        onSubmissionRejected?(prompt)
        island.transition(to: .peek(.failure(
            message: message, resume: nil, configuration: configuration
        )))
    }

    /// Asynchronous rejection (resolver miss, runner rejection): preserve the
    /// input, drop the provisional live-run dot if no real run is live, and
    /// peek — guarded, in case the user reopened the field meanwhile.
    private func rejectAsync(prompt: String, message: String, configuration: Bool = false) {
        onSubmissionRejected?(prompt)
        if liveHandle == nil {
            island.clearLiveRun()
            runStatus.clear() // the provisional Enter-time status never ran
        }
        showPeek(.failure(message: message, resume: nil, configuration: configuration))
    }

    /// Per-vault session-ID storage (DefaultsKey.lastSessionID) — the
    /// Phase-4 "continue last session" toggle reads this.
    private func persistSessionID(_ sessionID: String?) {
        guard let sessionID, let vaultPath = runnerVaultPath else { return }
        defaults.set(sessionID, forKey: DefaultsKey.lastSessionID(vaultPath: vaultPath))
    }

    /// The Enter-time acknowledgment banner: "▶ <excerpt> — working…" when
    /// this submission runs now, "▶ <excerpt> — queued" when Enter-time state
    /// says it is heading for the queue (the runner's positioned "Queued #n"
    /// then replaces it once the pipeline lands). The excerpt is the prompt's
    /// first ~44 characters (RunStatusModel's shared, LedgeCore-tested
    /// helper — Character-boundary cut, ellipsized).
    private static func startPeekMessage(for prompt: String, queueBound: Bool) -> String {
        let excerpt = RunStatusModel.excerpt(of: prompt)
        return queueBound ? "▶ \(excerpt) — queued" : "▶ \(excerpt) — working…"
    }

    private static func message(for reason: RejectionReason) -> String {
        switch reason {
        case .queueFull:
            "Queue full (5) — wait for the current run"
        case .noBinary:
            "Claude Code not found — open Settings…"
        case .invalidVault:
            "Vault folder is missing or not a folder"
        case .shuttingDown:
            "Ledge is quitting"
        }
    }

    /// Setup problems (fixable in Settings) vs. transient run conditions.
    private static func isConfiguration(_ reason: RejectionReason) -> Bool {
        switch reason {
        case .noBinary, .invalidVault:
            true
        case .queueFull, .shuttingDown:
            false
        }
    }

    /// One-line cause, shared by the failure peek's first line and the
    /// history record's `failure(reason:)` (which keeps the stderr tail in
    /// its own field).
    private static func headline(for failure: RunFailure) -> String {
        switch failure.reason {
        case let .nonZeroExit(code):
            "Run failed (exit \(code))"
        case let .errorResult(subtype):
            "Run failed (\(subtype ?? "error result"))"
        case .timeout:
            "Run timed out"
        case .malformedStream:
            "Run produced no result"
        case let .spawnFailed(detail):
            "Couldn't launch Claude: \(detail)"
        }
    }

    private static func message(for failure: RunFailure) -> String {
        let headline = headline(for: failure)
        // §6: the failure peek shows the stderr tail — all of the last 3
        // lines, not just the final one.
        let tail = failure.stderrTail.filter { !$0.isEmpty }
        return tail.isEmpty ? headline : "\(headline)\n\(tail.joined(separator: "\n"))"
    }
}
