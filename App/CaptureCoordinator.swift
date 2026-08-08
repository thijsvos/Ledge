import Foundation
import LedgeCore
import os

/// Phase-3 seam: whatever runs agent prompts. `ClaudeRunner`'s @MainActor
/// façade adopts this in Phase 3 and is handed to `CaptureCoordinator` —
/// CaptureView and the coordinator API stay untouched.
@MainActor
protocol AgentRunSubmitting: AnyObject {
    /// `prompt` is everything after the leading `/` (untrimmed).
    func submitAgentRun(prompt: String)
}

/// Routes one submitted capture-field input (§5) and drives the island into
/// the resulting peek. Instant captures are performed synchronously — the
/// write is <5 ms in practice, well under the 50 ms budget — so the island
/// collapses into its peek immediately on Enter and the field never blocks on
/// I/O.
///
/// The vault path comes from UserDefaults key "vaultPath" (standard defaults).
/// The Settings UI arrives in Phase 4; Phase-2 QA sets the path via:
///
///     defaults write app.ledge.Ledge vaultPath '<path>'
@MainActor
final class CaptureCoordinator {
    nonisolated static let vaultPathDefaultsKey = "vaultPath"

    private let island: IslandController
    private let defaults: UserDefaults
    /// Nil until Phase 3 plugs ClaudeRunner in; `/` inputs then peek an info
    /// banner instead of running.
    weak var agentRunner: (any AgentRunSubmitting)?
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
    /// for an empty submit).
    func submit(_ input: String) {
        switch CaptureRouter.route(input) {
        case let .agent(prompt):
            if let agentRunner {
                agentRunner.submitAgentRun(prompt: prompt)
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
                restoreInput = input
            }
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
