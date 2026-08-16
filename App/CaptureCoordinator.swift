import Foundation
import LedgeCore
import os

/// The seam between the capture field and whatever runs agent prompts.
/// `AgentRunController` is the only adopter — a @MainActor façade over the
/// `ClaudeRunner` actor — so CaptureView and the coordinator never have to
/// cross into the runner's concurrency domain to submit a prompt.
@MainActor
protocol AgentRunSubmitting: AnyObject {
    /// `prompt` is everything after the leading `/` (untrimmed) — except
    /// that a prompt whose first token names a known slash command keeps its
    /// leading `/` (see `SlashCommandCatalog.restoringCommandSlash`), so the
    /// headless child dispatches the command instead of reading its name as
    /// prose. `modelChoice` is the ⌘↩ per-run model selection; `.configured`
    /// (every pre-chooser path) is the Settings default.
    func submitAgentRun(prompt: String, modelChoice: RunModelChoice)
}

extension AgentRunSubmitting {
    /// Default-choice shim so pre-chooser call sites compile (and behave)
    /// unchanged — protocols cannot carry default parameter values.
    func submitAgentRun(prompt: String) {
        submitAgentRun(prompt: prompt, modelChoice: .configured)
    }
}

/// The App layer's behavior table for Ledge's native slash commands
/// (`NativeCommand`): the coordinator decides WHICH command fires (pure,
/// LedgeCore-tested via `SubmitAction.decide`); these closures are HOW —
/// wired by NotchWindowController where the Settings/onboarding/runner
/// plumbing already lives. `/help` has no entry: its behavior is a plain
/// info peek, which the coordinator owns like every other submit peek.
@MainActor
struct NativeCommandActions {
    var openSettings: () -> Void = {}
    var runChecks: () -> Void = {}
    var revealVault: () -> Void = {}
    var resumeLastSession: () -> Void = {}
    var cancelRuns: () -> Void = {}
    var undoLastRun: () -> Void = {}
    var quit: () -> Void = {}
}

/// Routes one submitted capture-field input and drives the island into the
/// resulting peek. Precedence: an exact native command ("/name", trimmed —
/// `NativeCommand.match`) executes inside Ledge BEFORE the §5 router ever
/// sees the input (no capture written, no run spawned); everything else
/// follows §5 literally via the untouched `CaptureRouter`. Instant captures
/// are performed synchronously — the write is <5 ms in practice, well under
/// the 50 ms budget — so the island collapses into its peek immediately on
/// Enter and the field never blocks on I/O.
///
/// The vault path comes from UserDefaults key "vaultPath" (standard
/// defaults), written by the §7 Settings vault picker — `DefaultsKey.vaultPath`
/// is the shared constant. It is read fresh on every submit, so changing the
/// folder in Settings takes effect on the next Enter with no restart and no
/// cached `Vault`.
@MainActor
final class CaptureCoordinator {
    nonisolated static let vaultPathDefaultsKey = "vaultPath"

    private let island: IslandController
    private let defaults: UserDefaults
    /// Weak because `NotchWindowController` owns both objects — the
    /// coordinator must not keep the run controller alive past teardown. Nil
    /// only in tests that build a coordinator on its own; `/` inputs then peek
    /// an info banner instead of running.
    weak var agentRunner: (any AgentRunSubmitting)?
    /// The CURRENT slash-command catalog (owned by the window controller,
    /// rescanned once per island open). The catalog no longer feeds the
    /// suggestion UI (the list shows Ledge's native commands), but it is
    /// still consulted at submit time to restore the leading "/" on agent
    /// prompts whose first token names a known Claude command — headless
    /// claude only dispatches "/name …" prompts, so typed Claude commands
    /// keep working invisibly. The default empty catalog restores nothing
    /// (MVP behavior, and what LedgeCore-less tests get).
    var slashCommandCatalog: () -> SlashCommandCatalog = { SlashCommandCatalog() }
    /// Behaviors for the native commands; injected by NotchWindowController.
    /// The no-op defaults keep the coordinator constructible without wiring.
    var nativeActions = NativeCommandActions()
    /// The raw input of the last FAILED instant capture. Typed text must
    /// never be lost to a failure peek (leaving `.open` destroys CaptureView
    /// and its field state), so the view restores this the next time the
    /// island opens.
    private var restoreInput: String?
    private let logger = Logger(subsystem: "app.ledge", category: "capture")
    /// §10 hard budget "Enter→instant-capture file written ≤50 ms" is checked
    /// by scripts/perf-check.sh from this signposter's `capture.write`
    /// intervals. Emitted only when a capture actually runs — zero idle cost,
    /// no timers, no polling (§10).
    private let signposter = OSSignposter(subsystem: "app.ledge", category: "perf")

    init(
        island: IslandController,
        defaults: UserDefaults = .standard,
        agentRunner: (any AgentRunSubmitting)? = nil
    ) {
        self.island = island
        self.defaults = defaults
        self.agentRunner = agentRunner
    }

    /// Handles Enter in the capture field. Always transitions the island out
    /// of `.open` synchronously (into the resulting peek, or straight to idle
    /// for an empty submit). Native commands leave `.open` through their
    /// behavior (peek, dismiss-then-window, or app termination).
    ///
    /// `modelChoice` is the ⌘↩ per-run model selection; it is forwarded ONLY
    /// into the agent route — native commands and instant captures ignore it
    /// (there is no model to choose). The `.configured` default keeps every
    /// pre-chooser call site byte-identical.
    func submit(_ input: String, modelChoice: RunModelChoice = .configured) {
        switch SubmitAction.decide(input) {
        case let .native(command):
            execute(native: command)
        case let .routed(route):
            submit(route: route, rawInput: input, modelChoice: modelChoice)
        }
    }

    /// The §5 routes, exactly as before native commands existed. `rawInput`
    /// is the field text as typed — what a failed capture preserves.
    private func submit(route: CaptureRoute, rawInput: String, modelChoice: RunModelChoice) {
        switch route {
        case let .agent(prompt):
            if let agentRunner {
                // §5 hands the runner everything AFTER the "/", but a prompt
                // naming a known custom command/skill must reach claude WITH
                // the slash or the child reads it as prose (prompt content
                // is not part of the pinned §2.3 argv shape).
                agentRunner.submitAgentRun(
                    prompt: slashCommandCatalog().restoringCommandSlash(prompt),
                    modelChoice: modelChoice
                )
            } else {
                island.transition(to: .peek(.info(message: "Agent runs arrive in Phase 3")))
            }
        case let .instant(target, text):
            // Enter in an empty (or all-whitespace) field is a dismiss
            // reflex, not a capture: write nothing, peek nothing. App-layer
            // policy only — the router's "" → .daily mapping is untouched.
            guard !text.allSatisfy(\.isWhitespace) else {
                dismissToIdle()
                return
            }
            if !performInstantCapture(text, target: target) {
                restoreInput = rawInput
            }
        }
    }

    /// Executes a native command: no capture is written, no run spawned.
    /// `/help` peeks its banner here (the suggestion LIST with per-command
    /// summaries is the real help; the banner only fits one line); every
    /// other command runs through the injected App-layer behavior, which owns
    /// its own island follow-up (dismiss, peek, window, or termination).
    private func execute(native command: NativeCommand) {
        logger.info("native command /\(command.name, privacy: .public)")
        switch command {
        case .help:
            island.transition(to: .peek(.info(
                message: "text → daily · .i → inbox · /prompt → Claude agent · /command → Ledge"
            )))
        case .settings:
            nativeActions.openSettings()
        case .checks:
            nativeActions.runChecks()
        case .vault:
            nativeActions.revealVault()
        case .resume:
            nativeActions.resumeLastSession()
        case .cancel:
            nativeActions.cancelRuns()
        case .undo:
            nativeActions.undoLastRun()
        case .quit:
            nativeActions.quit()
        }
    }

    /// Hands back — exactly once — the input of the last failed capture.
    /// CaptureView calls this when the field (re)appears.
    func consumeRestoreInput() -> String? {
        defer { restoreInput = nil }
        return restoreInput
    }

    /// Preserves input for the next field appearance. Agent submissions that
    /// were rejected before ever running (no vault, invalid vault, no binary,
    /// queue full) report back through `AgentRunController.onSubmissionRejected`
    /// → here, mirroring the failed-instant-capture path: typed text is never
    /// lost to a failure peek.
    func preserveInput(_ input: String) {
        restoreInput = input
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

    /// Returns true when the entry was written; false on any failure (the
    /// caller then preserves the typed input for restore).
    private func performInstantCapture(_ text: String, target: InstantTarget) -> Bool {
        guard
            let path = defaults.string(forKey: Self.vaultPathDefaultsKey),
            !path.isEmpty
        else {
            logger.error("instant capture with no vault configured")
            // Configuration failure: the peek offers "Open Settings…" and its
            // tap opens Settings (§7 empty/error-states pass).
            island.transition(to: .peek(.failure(
                message: "No vault set — open Settings…",
                resume: nil,
                configuration: true
            )))
            return false
        }
        // The interval brackets vault validation + the write — the §10
        // "Enter→file written" work (submit calls this synchronously on
        // Enter; routing above it is microseconds). Ended on both paths so
        // begins are never left dangling; the resulting peek transition is
        // deliberately OUTSIDE the interval.
        let interval = signposter.beginInterval("capture.write", id: signposter.makeSignpostID())
        do {
            let root = URL(
                fileURLWithPath: (path as NSString).expandingTildeInPath,
                isDirectory: true
            )
            let vault = try Vault(root: root)
            let started = Date()
            let outcome = try InstantCapture.capture(text, target: target, in: vault)
            signposter.endInterval("capture.write", interval)
            if outcome.fellBackToDaily {
                island.transition(to: .peek(.info(message: "saved to daily (no inbox note)")))
            } else {
                island.transition(to: .peek(.success(
                    filesEdited: 1,
                    duration: Date().timeIntervalSince(started)
                )))
            }
            return true
        } catch {
            signposter.endInterval("capture.write", interval)
            logger.error("instant capture failed: \(error.localizedDescription, privacy: .public)")
            // Vault validation failures are configuration problems (fixable
            // in Settings); anything else is a plain write failure.
            island.transition(to: .peek(.failure(
                message: Self.message(for: error),
                resume: nil,
                configuration: error is VaultError
            )))
            return false
        }
    }

    private static func message(for error: Error) -> String {
        if let vaultError = error as? VaultError,
           let description = vaultError.errorDescription
        {
            return description
        }
        return "Capture failed: \(error.localizedDescription)"
    }
}
