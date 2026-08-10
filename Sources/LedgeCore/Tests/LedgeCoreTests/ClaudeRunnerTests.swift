@testable import LedgeCore
import XCTest

/// §6 runner lifecycle against Tests/fixtures/fake-claude.sh (NEVER the real
/// CLI): success/edits/failure/garbage summaries, env sanitization proof,
/// timeout kill chain, FIFO queue + cap, terminateAll. Fast — every sleep and
/// timeout is fractions of a second.
final class ClaudeRunnerTests: XCTestCase {
    private var runner: ClaudeRunner?

    override func tearDown() async throws {
        await runner?.terminateAll()
        runner = nil
    }

    // MARK: - Helpers

    private func makeRunner(
        mode: String,
        timeout: TimeInterval = 30,
        grace: TimeInterval = 5,
        sleepSeconds: String? = nil,
        pollute: [String: String] = [:],
        binaryURL: URL = Fixtures.fakeClaude,
        vaultRoot: URL = Fixtures.vault
    ) throws -> ClaudeRunner {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment["FAKE_CLAUDE_MODE"] = mode
        if let sleepSeconds {
            environment["FAKE_CLAUDE_SLEEP"] = sleepSeconds
        }
        for (key, value) in pollute {
            environment[key] = value
        }
        let created = try ClaudeRunner(configuration: ClaudeRunner.Configuration(
            binaryURL: binaryURL,
            vault: Vault(root: vaultRoot),
            environment: environment,
            timeout: timeout,
            killGracePeriod: grace
        ))
        runner = created
        return created
    }

    private struct EventTimeout: Error {}

    /// Collects runner events until `completions` runCompleted events arrived,
    /// with a hard timeout so a hung runner fails the test instead of the run.
    private func collectEvents(
        from events: AsyncStream<RunnerEvent>,
        untilCompletions completions: Int,
        timeout: TimeInterval = 10
    ) async throws -> [RunnerEvent] {
        try await withThrowingTaskGroup(of: [RunnerEvent]?.self) { group in
            group.addTask {
                var collected: [RunnerEvent] = []
                var seen = 0
                for await event in events {
                    collected.append(event)
                    if case .runCompleted = event {
                        seen += 1
                        if seen == completions {
                            break
                        }
                    }
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            guard let first = try await group.next(), let result = first else {
                group.cancelAll()
                throw EventTimeout()
            }
            group.cancelAll()
            return result
        }
    }

    private func firstCompletion(
        from events: AsyncStream<RunnerEvent>,
        timeout: TimeInterval = 10
    ) async throws -> RunCompletion {
        let collected = try await collectEvents(from: events, untilCompletions: 1, timeout: timeout)
        for case let .runCompleted(completion) in collected {
            return completion
        }
        throw EventTimeout()
    }

    private func waitForChildDeath(of runner: ClaudeRunner, within: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline {
            if await !runner.lastChildIsRunningForTesting() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func waitForChildSpawn(of runner: ClaudeRunner, within: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline {
            if await runner.lastChildIsRunningForTesting() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    // MARK: - Invocation contract

    /// The exact argv (§2.3/§6 + live-probe findings): --verbose is required
    /// with print-mode stream-json; tools exactly Read,Write,Edit,Glob,Grep;
    /// --resume appended ONLY when a session ID is passed.
    func testExactSpawnArguments() {
        XCTAssertEqual(
            ClaudeRunner.arguments(prompt: "file my note", resumeSessionID: nil),
            [
                "-p", "file my note",
                "--output-format", "stream-json",
                "--verbose",
                "--allowedTools", "Read,Write,Edit,Glob,Grep",
                "--permission-mode", "acceptEdits",
                "--max-turns", "6",
                "--strict-mcp-config",
            ]
        )
        XCTAssertEqual(
            ClaudeRunner.arguments(prompt: "p", resumeSessionID: "abc-123").suffix(2),
            ["--resume", "abc-123"]
        )
    }

    func testModelAndEffortOverridesAppendAfterThePinnedInvocation() {
        let args = ClaudeRunner.arguments(
            prompt: "p", resumeSessionID: "abc-123", model: "sonnet", effort: "high"
        )
        // The §2.3 sandbox prefix is untouched…
        XCTAssertEqual(
            Array(args.prefix(12)),
            ClaudeRunner.arguments(prompt: "p", resumeSessionID: nil)
        )
        // …and the overrides slot in before --resume.
        XCTAssertEqual(
            Array(args.suffix(6)),
            ["--model", "sonnet", "--effort", "high", "--resume", "abc-123"]
        )
    }

    func testOverrideSanitizerDropsEmptyWhitespaceAndFlagLikeValues() {
        XCTAssertEqual(ClaudeRunner.sanitizeOverride("  sonnet\n"), "sonnet")
        XCTAssertNil(ClaudeRunner.sanitizeOverride(nil))
        XCTAssertNil(ClaudeRunner.sanitizeOverride(""))
        XCTAssertNil(ClaudeRunner.sanitizeOverride("   "))
        XCTAssertNil(ClaudeRunner.sanitizeOverride("--allowedTools"))
        XCTAssertNil(ClaudeRunner.sanitizeOverride("-x"))
        // A dropped override must leave the argv byte-identical to no override.
        XCTAssertEqual(
            ClaudeRunner.arguments(prompt: "p", resumeSessionID: nil, model: "-bad", effort: " "),
            ClaudeRunner.arguments(prompt: "p", resumeSessionID: nil)
        )
    }

    // MARK: - Lifecycle vs fake-claude.sh

    func testSuccessRunSummary() async throws {
        let runner = try makeRunner(mode: "success")
        guard case .started = await runner.enqueue(prompt: "do it") else {
            return XCTFail("idle runner must start immediately")
        }
        let completion = try await firstCompletion(from: runner.events)
        guard case let .success(summary) = completion.outcome else {
            return XCTFail("expected success, got \(completion.outcome)")
        }
        XCTAssertEqual(summary.sessionID?.hasPrefix("fake-session-"), true)
        XCTAssertEqual(summary.editedFiles, [])
        XCTAssertEqual(summary.durationMS, 1234)
        XCTAssertEqual(summary.numTurns, 1)
        XCTAssertEqual(summary.resultText, "Done. Appended the task to today's daily note.")
    }

    /// 3 tool_use blocks over 2 unique paths → exactly the 2 paths, in order.
    func testEditsRunCollectsUniqueFilePaths() async throws {
        let runner = try makeRunner(mode: "edits")
        _ = await runner.enqueue(prompt: "edit stuff")
        let completion = try await firstCompletion(from: runner.events)
        guard case let .success(summary) = completion.outcome else {
            return XCTFail("expected success, got \(completion.outcome)")
        }
        XCTAssertEqual(summary.editedFiles, ["daily/2026-08-08.md", "notes/new-note.md"])
    }

    func testFailureRunCarriesExitCodeAndStderrTail() async throws {
        let runner = try makeRunner(mode: "failure")
        _ = await runner.enqueue(prompt: "fail")
        let completion = try await firstCompletion(from: runner.events)
        guard case let .failure(failure) = completion.outcome else {
            return XCTFail("expected failure, got \(completion.outcome)")
        }
        XCTAssertEqual(failure.reason, .nonZeroExit(1))
        XCTAssertEqual(failure.stderrTail, [
            "Error: fake transport failure",
            "Caused by: FAKE_CLAUDE_MODE=failure",
            "Giving up after 1 attempt",
        ], "stderr tail must be exactly the last 3 lines")
        XCTAssertEqual(failure.sessionID?.hasPrefix("fake-session-"), true)
    }

    /// Exit 0 without a result event = malformed stream.
    func testGarbageRunIsMalformedStream() async throws {
        let runner = try makeRunner(mode: "garbage")
        _ = await runner.enqueue(prompt: "garbage")
        let completion = try await firstCompletion(from: runner.events)
        guard case let .failure(failure) = completion.outcome else {
            return XCTFail("expected failure, got \(completion.outcome)")
        }
        XCTAssertEqual(failure.reason, .malformedStream)
        XCTAssertNil(failure.sessionID)
    }

    /// A result event with is_error=true (or subtype ≠ success) on a ZERO exit
    /// is an errorResult failure carrying the CLI-reported subtype — never a
    /// self-contradictory "exit 0" failure.
    func testErrorResultOnZeroExitIsErrorResultFailure() async throws {
        let runner = try makeRunner(mode: "errorresult")
        _ = await runner.enqueue(prompt: "loop forever")
        let completion = try await firstCompletion(from: runner.events)
        guard case let .failure(failure) = completion.outcome else {
            return XCTFail("expected failure, got \(completion.outcome)")
        }
        XCTAssertEqual(failure.reason, .errorResult(subtype: "error_max_turns"))
        XCTAssertEqual(failure.sessionID?.hasPrefix("fake-session-"), true)
    }

    /// §2.2 integration proof: ANTHROPIC_API_KEY polluted into the parent env
    /// of the spawn config never reaches the child (envcheck exits 3 on leak).
    func testEnvironmentSanitizationIntegration() async throws {
        let runner = try makeRunner(
            mode: "envcheck",
            pollute: ["ANTHROPIC_API_KEY": "sk-test-leaked-from-shell"]
        )
        _ = await runner.enqueue(prompt: "check env")
        let completion = try await firstCompletion(from: runner.events)
        guard case .success = completion.outcome else {
            return XCTFail("key leaked into child env: \(completion.outcome)")
        }
    }

    func testSpawnFailureIsReported() async throws {
        // A directory passes the executable pre-check but cannot be exec'd.
        let runner = try makeRunner(mode: "success", binaryURL: Fixtures.fixturesDir)
        _ = await runner.enqueue(prompt: "spawn")
        let completion = try await firstCompletion(from: runner.events)
        guard case let .failure(failure) = completion.outcome,
              case .spawnFailed = failure.reason
        else {
            return XCTFail("expected spawnFailed, got \(completion.outcome)")
        }
    }

    // MARK: - Timeout kill chain

    /// timeout 0.5 s → SIGTERM, grace 0.5 s → SIGKILL; the child must actually
    /// be dead afterwards.
    func testTimeoutTerminatesChild() async throws {
        let runner = try makeRunner(mode: "slow", timeout: 0.5, grace: 0.5, sleepSeconds: "30")
        _ = await runner.enqueue(prompt: "slow")
        let completion = try await firstCompletion(from: runner.events, timeout: 8)
        guard case let .failure(failure) = completion.outcome else {
            return XCTFail("expected timeout failure, got \(completion.outcome)")
        }
        XCTAssertEqual(failure.reason, .timeout)
        XCTAssertEqual(failure.sessionID?.hasPrefix("fake-session-"), true)
        let dead = await waitForChildDeath(of: runner)
        XCTAssertTrue(dead, "child process must not survive the timeout kill chain")
    }

    // MARK: - Queue

    /// One live slow run; two more submits queue at positions 1 and 2 and then
    /// execute in FIFO order, with queueChanged depths observed.
    func testQueueFIFOOrderAndPositions() async throws {
        let runner = try makeRunner(mode: "slow", sleepSeconds: "0.3")
        guard case let .started(first) = await runner.enqueue(prompt: "run-1") else {
            return XCTFail("first submit must start")
        }
        guard case let .queued(second, position: p1) = await runner.enqueue(prompt: "run-2") else {
            return XCTFail("second submit must queue")
        }
        guard case let .queued(third, position: p2) = await runner.enqueue(prompt: "run-3") else {
            return XCTFail("third submit must queue")
        }
        XCTAssertEqual(p1, 1)
        XCTAssertEqual(p2, 2)

        let events = try await collectEvents(from: runner.events, untilCompletions: 3, timeout: 12)
        let startedOrder = events.compactMap { event -> RunHandle? in
            if case let .runStarted(handle) = event {
                return handle
            }
            return nil
        }
        XCTAssertEqual(startedOrder, [first, second, third], "FIFO execution order")
        let completedOrder = events.compactMap { event -> RunHandle? in
            if case let .runCompleted(completion) = event {
                return completion.handle
            }
            return nil
        }
        XCTAssertEqual(completedOrder, [first, second, third])
        let depths = events.compactMap { event -> Int? in
            if case let .queueChanged(depth) = event {
                return depth
            }
            return nil
        }
        XCTAssertEqual(depths, [1, 2, 1, 0], "enqueue ×2 then dequeue ×2")
    }

    /// 7 rapid submits: 1 live + 5 queued, the 7th (6th pending) rejected.
    func testSeventhRapidSubmitIsRejectedQueueFull() async throws {
        let runner = try makeRunner(mode: "slow", sleepSeconds: "2")
        var started = 0, queued = 0, rejected: [RejectionReason] = []
        for index in 1 ... 7 {
            switch await runner.enqueue(prompt: "run-\(index)") {
            case .started: started += 1
            case .queued: queued += 1
            case let .rejected(reason): rejected.append(reason)
            }
        }
        XCTAssertEqual(started, 1)
        XCTAssertEqual(queued, 5)
        XCTAssertEqual(rejected, [.queueFull], "exactly one rejection, and it is queueFull")
        await runner.terminateAll()
    }

    /// terminateAll: SIGTERM the live child, drop every queued run, and reject
    /// everything afterwards — a child spawned after a terminate would be
    /// orphaned at app exit (§6) or race a replacement runner (§2.4).
    func testTerminateAllKillsLiveAndDrainsQueue() async throws {
        let runner = try makeRunner(mode: "slow", sleepSeconds: "2")
        guard case .started = await runner.enqueue(prompt: "live") else {
            return XCTFail("must start")
        }
        _ = await runner.enqueue(prompt: "queued-1")
        _ = await runner.enqueue(prompt: "queued-2")

        await runner.terminateAll()

        let completion = try await firstCompletion(from: runner.events, timeout: 8)
        guard case .failure = completion.outcome else {
            return XCTFail("SIGTERMed run must complete as failure")
        }
        XCTAssertEqual(completion.handle.prompt, "live")
        let dead = await waitForChildDeath(of: runner)
        XCTAssertTrue(dead)
        // Shutdown is terminal: no run may ever spawn after terminateAll.
        guard case .rejected(reason: .shuttingDown) = await runner.enqueue(prompt: "after") else {
            return XCTFail("enqueue after terminateAll must be rejected, not spawned")
        }
    }

    /// The /cancel history seam: after terminateAll SIGTERMs a live run, the
    /// parser's extracted session ID stays readable via
    /// `lastObservedSessionID` — the App layer records the cancelled run from
    /// exactly this, because it stops consuming events before the SIGTERMed
    /// child's completion is emitted.
    func testLastObservedSessionIDSurvivesTermination() async throws {
        let runner = try makeRunner(mode: "slow", sleepSeconds: "30")
        guard case .started = await runner.enqueue(prompt: "live") else {
            return XCTFail("must start")
        }
        // slow mode emits the init event (with the session ID) immediately;
        // poll until the parser has seen it.
        let deadline = Date().addingTimeInterval(5)
        var observed: String?
        while observed == nil, Date() < deadline {
            observed = await runner.lastObservedSessionID
            if observed == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertNotNil(observed, "init event must have carried a session ID")

        await runner.terminateAll()

        let afterKill = await runner.lastObservedSessionID
        XCTAssertEqual(afterKill, observed)
        XCTAssertEqual(afterKill?.hasPrefix("fake-session-"), true)
    }

    /// terminateAll returns only once the child is actually dead — the caller
    /// may immediately spawn a replacement runner in the SAME vault (§2.4:
    /// one live run per vault), so returning early would overlap two agents.
    func testTerminateAllWaitsForChildExit() async throws {
        let runner = try makeRunner(mode: "slow", grace: 2, sleepSeconds: "30")
        guard case .started = await runner.enqueue(prompt: "live") else {
            return XCTFail("must start")
        }
        let spawned = await waitForChildSpawn(of: runner)
        XCTAssertTrue(spawned, "child must have spawned before terminating")

        await runner.terminateAll()

        let stillRunning = await runner.lastChildIsRunningForTesting()
        XCTAssertFalse(stillRunning, "terminateAll must not return while the child is alive")
    }

    /// terminateNow (the synchronous quit path): SIGTERMs the live child from
    /// a nonisolated context and turns the runner terminal.
    func testTerminateNowKillsLiveChildAndRejectsFurtherEnqueues() async throws {
        let runner = try makeRunner(mode: "slow", sleepSeconds: "30")
        guard case .started = await runner.enqueue(prompt: "live") else {
            return XCTFail("must start")
        }
        let spawned = await waitForChildSpawn(of: runner)
        XCTAssertTrue(spawned, "child must have spawned before terminating")

        runner.terminateNow() // synchronous — no await

        let completion = try await firstCompletion(from: runner.events, timeout: 8)
        guard case .failure = completion.outcome else {
            return XCTFail("SIGTERMed run must complete as failure")
        }
        let dead = await waitForChildDeath(of: runner)
        XCTAssertTrue(dead, "terminateNow must actually kill the child")
        guard case .rejected(reason: .shuttingDown) = await runner.enqueue(prompt: "after") else {
            return XCTFail("enqueue after terminateNow must be rejected")
        }
    }

    /// Quit-vs-spawn race (flow G): `terminateNow()` interleaving between
    /// execute()'s pre-spawn shutdown check and its pid publication — possible
    /// because terminateNow is nonisolated and runs on the quitting main
    /// thread in true parallel with the actor — must still kill the
    /// just-spawned child. The publication re-reads the shutdown flag inside
    /// the same lock section and signals the child itself when a terminate
    /// slipped in. The test hook makes the ~1 ms window deterministic.
    func testTerminateNowInSpawnRaceWindowStillKillsChild() async throws {
        let runner = try makeRunner(mode: "slow", sleepSeconds: "30")
        await runner.setSpawnRaceWindowHookForTesting { [weak runner] in
            runner?.terminateNow()
        }
        _ = await runner.enqueue(prompt: "race")
        let completion = try await firstCompletion(from: runner.events, timeout: 8)
        guard case .failure = completion.outcome else {
            return XCTFail("raced run must complete as failure, got \(completion.outcome)")
        }
        let dead = await waitForChildDeath(of: runner)
        XCTAssertTrue(dead, "a child spawned inside the race window must still be killed")
        guard case .rejected(reason: .shuttingDown) = await runner.enqueue(prompt: "after") else {
            return XCTFail("enqueue after the raced terminate must be rejected")
        }
    }

    /// terminateAll returns the queued prompts it dropped (FIFO order) so the
    /// App layer can preserve/report them — prompts the user saw acknowledged
    /// with a "Queued #n" peek must never vanish silently on a vault/binary
    /// change.
    func testTerminateAllReturnsDroppedQueuedPrompts() async throws {
        let runner = try makeRunner(mode: "slow", sleepSeconds: "2")
        guard case .started = await runner.enqueue(prompt: "live") else {
            return XCTFail("must start")
        }
        _ = await runner.enqueue(prompt: "queued-1")
        _ = await runner.enqueue(prompt: "queued-2")
        let dropped = await runner.terminateAll()
        XCTAssertEqual(dropped, ["queued-1", "queued-2"], "dropped prompts, FIFO order")
        let droppedAgain = await runner.terminateAll()
        XCTAssertEqual(droppedAgain, [], "second terminateAll has nothing left to drop")
    }

    // MARK: - Pre-flight rejections

    func testMissingBinaryIsRejected() async throws {
        let runner = try makeRunner(
            mode: "success",
            binaryURL: URL(fileURLWithPath: "/nonexistent/claude-\(UUID().uuidString)")
        )
        guard case .rejected(reason: .noBinary) = await runner.enqueue(prompt: "x") else {
            return XCTFail("expected noBinary rejection")
        }
    }

    func testVanishedVaultIsRejected() async throws {
        let vaultRoot = try Fixtures.makeTempVaultCopy()
        let runner = try makeRunner(mode: "success", vaultRoot: vaultRoot)
        try FileManager.default.removeItem(at: vaultRoot)
        guard case .rejected(reason: .invalidVault) = await runner.enqueue(prompt: "x") else {
            return XCTFail("expected invalidVault rejection")
        }
    }
}
