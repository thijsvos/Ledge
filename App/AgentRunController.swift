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
    private let defaults: UserDefaults
    /// One resolver per launch so the login-shell fallback (`/bin/zsh -lc
    /// 'command -v claude'`) runs at most once (§6). Sendable — `resolve()`
    /// is always called OFF the main actor (the login shell must never block
    /// the UI).
    private let resolver: ClaudeBinaryResolver
    private var runner: ClaudeRunner?
    private var runnerVaultPath: String?
    private var runnerBinaryPath: String?
    private var eventsTask: Task<Void, Never>?
    /// Drains a retired runner (vault/binary changed): terminateAll SIGTERMs,
    /// escalates to SIGKILL, and returns only once the old child is dead.
    /// Every enqueue on the replacement awaits this first — §2.4: one live
    /// run per vault, so the old and new child must never overlap.
    private var retirementDrain: Task<Void, Never>?
    /// Mirrors the runner's pending-queue depth (from queueChanged events) so
    /// completion handling knows whether another run follows immediately.
    private var queueDepth = 0
    /// The handle of the run the runner reported live (from runStarted /
    /// completion events). Distinct from `island.liveRun`, which may briefly
    /// hold a provisional handle between Enter and the runner's confirmation.
    private var liveHandle: RunHandle?
    /// Reports a submission that was rejected before it ever ran (no vault,
    /// bad vault, no binary, queue full) so CaptureCoordinator can preserve
    /// the typed input — text is never lost to a failure peek.
    var onSubmissionRejected: ((_ prompt: String) -> Void)?
    private let logger = Logger(subsystem: "app.ledge", category: "runner")

    init(island: IslandController, defaults: UserDefaults = .standard) {
        self.island = island
        self.defaults = defaults
        resolver = ClaudeBinaryResolver() // Settings override arrives in Phase 4
    }

    // MARK: - AgentRunSubmitting

    func submitAgentRun(prompt: String) {
        guard
            let configuredPath = defaults.string(forKey: CaptureCoordinator.vaultPathDefaultsKey),
            !configuredPath.isEmpty
        else {
            reject(prompt: prompt, message: "No vault set — Settings arrive in Phase 4")
            return
        }
        let vaultPath = (configuredPath as NSString).expandingTildeInPath
        let vault: Vault
        do {
            vault = try Vault(root: URL(fileURLWithPath: vaultPath, isDirectory: true))
        } catch {
            reject(
                prompt: prompt,
                message: (error as? VaultError)?.errorDescription ?? "Vault path is invalid"
            )
            return
        }

        // §5: Enter leaves `.open` synchronously — the running dot shows
        // immediately. If a run is already live its handle keeps the dot;
        // otherwise a provisional handle stands in until the runner confirms
        // (`.started` replaces it; a rejection clears it again).
        island.transition(to: .running(liveHandle ?? RunHandle(prompt: prompt)))

        let resolver = resolver
        Task { [weak self] in
            // Off the main actor: the login-shell fallback can take seconds.
            let binaryPath = await Task.detached { resolver.resolve() }.value
            guard let self else { return }
            guard let binaryPath else {
                // Full onboarding arrives in Phase 4; for now the peek is the state.
                rejectAsync(
                    prompt: prompt,
                    message: "Claude Code not found — install the claude CLI"
                )
                return
            }
            let runner = ensureRunner(vault: vault, vaultPath: vaultPath, binaryPath: binaryPath)
            // Never enqueue while a retired runner's child may still be alive.
            await retirementDrain?.value
            let enqueued = await runner.enqueue(prompt: prompt)
            handle(enqueued: enqueued, prompt: prompt)
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

    // MARK: - Quit

    /// App quit (§6): SIGTERM the live child. `terminateNow()` is nonisolated
    /// and synchronous — the signal is sent before this returns, with no
    /// semaphore and no dependence on executor scheduling during termination.
    /// It also marks the runner as shutting down, so nothing new can spawn in
    /// the window before process exit.
    func shutdown() {
        eventsTask?.cancel()
        eventsTask = nil
        runner?.terminateNow()
    }

    // MARK: - Runner lifetime & events

    private func ensureRunner(vault: Vault, vaultPath: String, binaryPath: String) -> ClaudeRunner {
        if let runner, runnerVaultPath == vaultPath, runnerBinaryPath == binaryPath {
            return runner
        }
        if let previous = runner {
            logger.info("vault or binary changed — retiring previous runner")
            eventsTask?.cancel()
            // The retired runner's completion events are never consumed, so
            // clear the live-run bookkeeping now — otherwise dismiss/peek
            // expiry would keep restoring `.running(staleHandle)` forever.
            island.clearLiveRun()
            liveHandle = nil
            queueDepth = 0
            let previousDrain = retirementDrain
            retirementDrain = Task.detached {
                await previousDrain?.value
                await previous.terminateAll() // waits until the child is dead
            }
        }
        let created = ClaudeRunner(configuration: ClaudeRunner.Configuration(
            binaryURL: URL(fileURLWithPath: binaryPath),
            vault: vault
        ))
        runner = created
        runnerVaultPath = vaultPath
        runnerBinaryPath = binaryPath
        queueDepth = 0
        eventsTask = Task { [weak self] in
            for await event in created.events {
                self?.handle(event: event)
            }
        }
        return created
    }

    private func handle(enqueued: Enqueued, prompt: String) {
        switch enqueued {
        case let .started(handle):
            showRunning(handle)
        case let .queued(_, position):
            showPeek(.queued(position: position))
        case let .rejected(reason):
            rejectAsync(prompt: prompt, message: Self.message(for: reason))
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
        liveHandle = nil
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

    // MARK: - Guarded transitions

    /// A run started. Transition to `.running` unless the island is showing
    /// something that must survive: the previous run's completion peek (§4:
    /// banners show for their full 2.5 s) or the open capture field (whose
    /// typed text a transition would destroy). In those cases only the
    /// live-run bookkeeping updates; peek expiry / dismiss then falls back to
    /// `.running(handle)`.
    private func showRunning(_ handle: RunHandle) {
        liveHandle = handle
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
    /// typed input is preserved via `onSubmissionRejected`.
    private func reject(prompt: String, message: String) {
        onSubmissionRejected?(prompt)
        island.transition(to: .peek(.failure(message: message, resume: nil)))
    }

    /// Asynchronous rejection (resolver miss, runner rejection): preserve the
    /// input, drop the provisional live-run dot if no real run is live, and
    /// peek — guarded, in case the user reopened the field meanwhile.
    private func rejectAsync(prompt: String, message: String) {
        onSubmissionRejected?(prompt)
        if liveHandle == nil {
            island.clearLiveRun()
        }
        showPeek(.failure(message: message, resume: nil))
    }

    /// UserDefaults key "lastSessionID:<vaultPath>" (App layer only) — the
    /// Phase-4 "continue last session" toggle reads this.
    private func persistSessionID(_ sessionID: String?) {
        guard let sessionID, let vaultPath = runnerVaultPath else { return }
        defaults.set(sessionID, forKey: "lastSessionID:\(vaultPath)")
    }

    private static func message(for reason: RejectionReason) -> String {
        switch reason {
        case .queueFull:
            "Queue full (5) — wait for the current run"
        case .noBinary:
            "Claude Code not found — install the claude CLI"
        case .invalidVault:
            "Vault folder is missing or not a folder"
        case .shuttingDown:
            "Ledge is quitting"
        }
    }

    private static func message(for failure: RunFailure) -> String {
        let headline = switch failure.reason {
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
        // §6: the failure peek shows the stderr tail — all of the last 3
        // lines, not just the final one.
        let tail = failure.stderrTail.filter { !$0.isEmpty }
        return tail.isEmpty ? headline : "\(headline)\n\(tail.joined(separator: "\n"))"
    }
}
