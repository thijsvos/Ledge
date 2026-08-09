@testable import LedgeCore
import XCTest

/// §4 state machine: full 5×5 transition matrix, no-op acceptance,
/// hover-only-from-collapsed, peek expiry, liveRun bookkeeping.
@MainActor
final class StateMachineTests: XCTestCase {
    private let handle = RunHandle(prompt: "summarize inbox")
    private let otherHandle = RunHandle(prompt: "file today's note")
    private let peekContent = PeekContent.info(message: "hello")

    /// One representative state per case (payloads included).
    private var representativeStates: [IslandState] {
        [.collapsed, .hover, .open, .running(handle), .peek(peekContent)]
    }

    /// A controller driven into `state` via legal transitions. Long peek
    /// duration so expiry never fires mid-test unless requested.
    private func makeController(
        in state: IslandState,
        peekDuration: TimeInterval = 60
    ) -> IslandController {
        let controller = IslandController(peekDuration: peekDuration)
        if state != .collapsed {
            XCTAssertTrue(controller.transition(to: state), "failed to reach \(state.caseName)")
        }
        return controller
    }

    // MARK: - Matrix

    func testInitialState() {
        let controller = IslandController()
        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertNil(controller.liveRun)
    }

    /// The full 5×5 matrix. Legality rule: identical state = accepted no-op;
    /// `.hover` reachable ONLY from `.collapsed`; everything else legal.
    func testFullTransitionMatrix() {
        for from in representativeStates {
            for to in representativeStates {
                let controller = makeController(in: from)
                let expected: Bool = if from == to {
                    true
                } else if case .hover = to {
                    from == .collapsed
                } else {
                    true
                }
                let accepted = controller.transition(to: to)
                XCTAssertEqual(
                    accepted, expected,
                    "\(from.caseName) -> \(to.caseName): expected \(expected ? "accept" : "reject")"
                )
                XCTAssertEqual(
                    controller.state, accepted ? to : from,
                    "\(from.caseName) -> \(to.caseName): wrong resulting state"
                )
            }
        }
    }

    func testHoverOnlyReachableFromCollapsed() {
        XCTAssertTrue(makeController(in: .collapsed).transition(to: .hover))
        XCTAssertFalse(makeController(in: .open).transition(to: .hover))
        XCTAssertFalse(makeController(in: .running(handle)).transition(to: .hover))
        XCTAssertFalse(makeController(in: .peek(peekContent)).transition(to: .hover))
    }

    func testIdenticalTransitionIsAcceptedNoOp() {
        let controller = makeController(in: .open)
        XCTAssertTrue(controller.transition(to: .open))
        XCTAssertEqual(controller.state, .open)
    }

    func testRejectedTransitionLeavesStateUnchanged() {
        let controller = makeController(in: .running(handle))
        XCTAssertFalse(controller.transition(to: .hover))
        XCTAssertEqual(controller.state, .running(handle))
        XCTAssertEqual(controller.liveRun, handle)
    }

    /// Same case, different payload: a normal accepted transition.
    func testDifferentPayloadSameCaseIsAccepted() {
        let controller = makeController(in: .running(handle))
        XCTAssertTrue(controller.transition(to: .running(otherHandle)))
        XCTAssertEqual(controller.state, .running(otherHandle))
        XCTAssertEqual(controller.liveRun, otherHandle)

        let peeking = makeController(in: .peek(.queued(position: 1)))
        XCTAssertTrue(peeking.transition(to: .peek(.queued(position: 2))))
        XCTAssertEqual(peeking.state, .peek(.queued(position: 2)))
    }

    // MARK: - openGeneration bookkeeping

    /// The open-session token async work (the /resume history load) uses to
    /// detect a dismiss→reopen behind its back: every accepted entry INTO
    /// `.open` from another state bumps it; the no-op `.open → .open` and
    /// transitions that never enter `.open` do not.
    func testOpenGenerationBumpsOnlyOnEntryIntoOpen() {
        let controller = IslandController()
        XCTAssertEqual(controller.openGeneration, 0)

        controller.transition(to: .open)
        XCTAssertEqual(controller.openGeneration, 1)
        controller.transition(to: .open) // no-op re-open: same session
        XCTAssertEqual(controller.openGeneration, 1)

        // Dismiss → reopen: a NEW open session.
        controller.transition(to: .collapsed)
        XCTAssertEqual(controller.openGeneration, 1)
        controller.transition(to: .open)
        XCTAssertEqual(controller.openGeneration, 2)

        // Leave for .running (Enter submits) → tap back open: new session too.
        controller.transition(to: .running(handle))
        controller.transition(to: .open)
        XCTAssertEqual(controller.openGeneration, 3)

        // Transitions not entering .open never bump it.
        controller.transition(to: .peek(peekContent))
        controller.transition(to: .collapsed)
        controller.transition(to: .hover)
        XCTAssertEqual(controller.openGeneration, 3)
    }

    func testRejectedTransitionDoesNotBumpOpenGeneration() {
        let controller = makeController(in: .running(handle))
        let before = controller.openGeneration
        XCTAssertFalse(controller.transition(to: .hover)) // illegal
        XCTAssertEqual(controller.openGeneration, before)
    }

    // MARK: - liveRun bookkeeping

    func testRunningTransitionSetsLiveRun() {
        let controller = IslandController()
        XCTAssertNil(controller.liveRun)
        controller.transition(to: .running(handle))
        XCTAssertEqual(controller.liveRun, handle)
    }

    func testLiveRunSurvivesLeavingRunning() {
        let controller = makeController(in: .running(handle))
        controller.transition(to: .collapsed)
        XCTAssertEqual(controller.liveRun, handle, "leaving .running must not clear liveRun")
        controller.clearLiveRun()
        XCTAssertNil(controller.liveRun)
    }

    /// `setLiveRun` records a run WITHOUT a state transition — a queued run
    /// starting behind a completion peek (or the open field) must not destroy
    /// what the user is looking at.
    func testSetLiveRunDoesNotChangeState() {
        let peeking = makeController(in: .peek(peekContent))
        peeking.setLiveRun(handle)
        XCTAssertEqual(peeking.state, .peek(peekContent), "setLiveRun must not transition")
        XCTAssertEqual(peeking.liveRun, handle)

        let open = makeController(in: .open)
        open.setLiveRun(otherHandle)
        XCTAssertEqual(open.state, .open)
        XCTAssertEqual(open.liveRun, otherHandle)
    }

    /// After the peek expires, the island falls back to the run recorded via
    /// setLiveRun — the next queued run's dot appears once the banner is done.
    func testPeekExpiryFallsBackToRunSetViaSetLiveRun() async throws {
        let controller = IslandController(peekDuration: 0.05)
        controller.transition(to: .peek(.success(filesEdited: 1, duration: 1)))
        controller.setLiveRun(handle) // next queued run started behind the peek
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(controller.state, .running(handle))
    }

    // MARK: - Peek expiry

    func testPeekExpiryReturnsToRunningWhenLiveRunSet() async throws {
        let controller = IslandController(peekDuration: 0.05)
        controller.transition(to: .running(handle))
        controller.transition(to: .peek(.queued(position: 1)))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(controller.state, .running(handle))
    }

    func testPeekExpiryCollapsesWithoutLiveRun() async throws {
        let controller = IslandController(peekDuration: 0.05)
        controller.transition(to: .peek(.info(message: "hi")))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(controller.state, .collapsed)
    }

    func testPeekExpiryCollapsesAfterLiveRunCleared() async throws {
        let controller = IslandController(peekDuration: 0.05)
        controller.transition(to: .running(handle))
        controller.clearLiveRun() // run finished
        controller.transition(to: .peek(.success(filesEdited: 2, duration: 34)))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(controller.state, .collapsed)
    }

    func testPeekExpiryCancelledWhenSuperseded() async throws {
        let controller = IslandController(peekDuration: 0.05)
        controller.transition(to: .peek(.info(message: "hi")))
        controller.transition(to: .open) // user opened before expiry
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(controller.state, .open, "expiry must not fire after leaving .peek")
    }

    func testReplacingPeekRestartsExpiry() async throws {
        let controller = IslandController(peekDuration: 0.2)
        controller.transition(to: .peek(.info(message: "first")))
        try await Task.sleep(for: .milliseconds(120))
        controller.transition(to: .peek(.info(message: "second")))
        try await Task.sleep(for: .milliseconds(120))
        // First clock would have fired by now; the restarted one has not.
        XCTAssertEqual(controller.state, .peek(.info(message: "second")))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(controller.state, .collapsed)
    }
}
