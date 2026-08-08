// Island state machine (§4 of the architecture doc). Pure types plus the
// single mutation point, `IslandController.transition(to:)`.

import Foundation
import Observation
import os

/// Identifies one agent run for the lifetime of the app session.
public struct RunHandle: Sendable, Equatable {
    public let id: UUID
    public let prompt: String

    public init(id: UUID = UUID(), prompt: String) {
        self.id = id
        self.prompt = prompt
    }
}

/// The §6 escape hatch attached to a failure peek: everything needed to
/// resume the exact session in a real terminal ("Open in Terminal" / "Copy
/// command"). Nil when there is no session to resume.
public struct ResumeAction: Sendable, Equatable {
    public let vaultPath: String
    public let sessionID: String

    public init(vaultPath: String, sessionID: String) {
        self.vaultPath = vaultPath
        self.sessionID = sessionID
    }
}

/// What a 2.5 s peek banner shows.
public enum PeekContent: Sendable, Equatable {
    case success(filesEdited: Int, duration: TimeInterval)
    /// `configuration` marks failures whose cause is missing/invalid setup
    /// (no vault, invalid vault, no binary) rather than a run going wrong.
    /// A configuration failure with no resume offers "Open Settings…" and its
    /// tap opens Settings (§7 empty/error-states pass).
    case failure(message: String, resume: ResumeAction?, configuration: Bool)
    case queued(position: Int)
    case info(message: String)
}

public extension PeekContent {
    /// Two-argument convenience keeping Phase-3 call sites/tests source-stable:
    /// a plain (non-configuration) failure.
    static func failure(message: String, resume: ResumeAction?) -> PeekContent {
        .failure(message: message, resume: resume, configuration: false)
    }
}

/// The island's UI state (§4).
public enum IslandState: Equatable, Sendable {
    /// Pixel-identical to the physical notch.
    case collapsed
    /// Grown ~10 pt, affordance hint.
    case hover
    /// Capture field visible, panel is key.
    case open
    /// Collapsed + animated status dot at the notch edge.
    case running(RunHandle)
    /// Banner for 2.5 s: success / failure / queued / info.
    case peek(PeekContent)
}

public extension IslandState {
    /// Stable case label for logging.
    var caseName: String {
        switch self {
        case .collapsed: "collapsed"
        case .hover: "hover"
        case .open: "open"
        case .running: "running"
        case .peek: "peek"
        }
    }
}

/// The ONLY place `IslandState` mutates. `@MainActor` because the UI observes
/// it directly; no AppKit/SwiftUI imports — the window layer reacts via
/// Observation.
///
/// Transition legality (full matrix; tested exhaustively):
///
/// ```
/// from \ to    collapsed   hover     open      running   peek
/// collapsed    ✓ no-op     ✓         ✓         ✓         ✓
/// hover        ✓           ✓ no-op   ✓         ✓         ✓
/// open         ✓           ✗         ✓ no-op   ✓         ✓
/// running      ✓           ✗         ✓         ✓ †       ✓
/// peek         ✓           ✗         ✓         ✓         ✓ †
/// ```
///
/// Rules: transitioning to the *identical* state (payload included) is an
/// accepted no-op; `.hover` is reachable ONLY from `.collapsed`; every other
/// transition is legal. († identical payload = no-op; a different payload is a
/// normal accepted transition, e.g. `.peek(a) → .peek(b)` replaces the banner.)
@MainActor
@Observable
public final class IslandController {
    public private(set) var state: IslandState = .collapsed

    /// The currently live agent run, if any. Set on every accepted transition
    /// into `.running`; cleared explicitly by the runner (Phase 3) via
    /// `clearLiveRun()` — leaving `.running` does NOT clear it, because peeks
    /// and `open` may overlay a still-live run.
    public private(set) var liveRun: RunHandle?

    private let logger = Logger(subsystem: "app.ledge", category: "island")
    private let signposter = OSSignposter(subsystem: "app.ledge", category: "perf")
    private let peekDuration: TimeInterval
    @ObservationIgnored private var peekExpiryTask: Task<Void, Never>?

    /// - Parameter peekDuration: how long a `.peek` shows before auto-expiring
    ///   (2.5 s per §4; injectable for tests).
    public init(peekDuration: TimeInterval = 2.5) {
        self.peekDuration = peekDuration
    }

    /// Attempts a state transition. Returns `false` (and leaves state
    /// unchanged) when the transition is illegal per the matrix above. Every
    /// accepted transition emits an os_signpost interval (subsystem
    /// "app.ledge", category "perf") and a log line; rejections log only.
    @discardableResult
    public func transition(to newState: IslandState) -> Bool {
        let current = state
        guard isLegal(from: current, to: newState) else {
            logger.info(
                "rejected transition \(current.caseName, privacy: .public) -> \(newState.caseName, privacy: .public)"
            )
            return false
        }

        let interval = signposter.beginInterval("island.transition", id: signposter.makeSignpostID())
        peekExpiryTask?.cancel()
        peekExpiryTask = nil
        state = newState
        if case let .running(handle) = newState {
            liveRun = handle
        }
        if case .peek = newState {
            schedulePeekExpiry()
        }
        logger.info(
            "transition \(current.caseName, privacy: .public) -> \(newState.caseName, privacy: .public)"
        )
        signposter.endInterval("island.transition", interval)
        return true
    }

    /// Called by the runner when the live run finishes (Phase 3). A subsequent
    /// peek expiry then falls back to `.collapsed` instead of `.running`.
    public func clearLiveRun() {
        liveRun = nil
    }

    /// Phase-3 runner bookkeeping: records a newly started run WITHOUT a state
    /// transition. Used when the island is showing something that must not be
    /// interrupted — the previous run's completion peek, or the open capture
    /// field (whose typed text a transition would destroy). The current UI
    /// stays; peek expiry and dismiss then fall back to `.running(handle)`.
    public func setLiveRun(_ handle: RunHandle) {
        liveRun = handle
    }

    private func isLegal(from: IslandState, to: IslandState) -> Bool {
        if from == to {
            return true
        } // identical state: accepted no-op
        if case .hover = to {
            return from == .collapsed
        } // hover only from collapsed
        return true // everything else is legal
    }

    /// Task-based expiry (no timers, no polling): after `peekDuration` the
    /// peek transitions to `.running(liveRun)` if a run is live, else
    /// `.collapsed`. Any accepted transition cancels the pending expiry
    /// (re-entering `.peek` restarts the clock).
    private func schedulePeekExpiry() {
        let duration = peekDuration
        peekExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return // cancelled
            }
            guard let self, !Task.isCancelled else { return }
            expirePeek()
        }
    }

    private func expirePeek() {
        guard case .peek = state else { return }
        if let liveRun {
            transition(to: .running(liveRun))
        } else {
            transition(to: .collapsed)
        }
    }
}
