// §6 ClaudeRunner: an actor owning a serialized FIFO queue — at most ONE
// child `claude` process is ever alive (§2.4, one run per vault). Spawns the
// user's official CLI (the ONLY integration, §2.1) with a sanitized
// environment (§2.2), the exact read/edit-only tool set (§2.3), and the vault
// as cwd (§2.5). Structured concurrency throughout; `waitUntilExit` is never
// used — termination is bridged into the actor via the termination handler.

import Foundation
import os

// MARK: - Public types

/// Result of `enqueue(prompt:)`.
public enum Enqueued: Sendable {
    case started(RunHandle)
    case queued(RunHandle, position: Int)
    case rejected(reason: RejectionReason)
}

public enum RejectionReason: Sendable, Equatable {
    /// 1 live + 5 pending already; the 6th pending prompt is rejected.
    case queueFull
    case noBinary
    case invalidVault
    /// `terminateAll()`/`terminateNow()` ran: the runner is retiring (vault or
    /// binary changed) or the app is quitting. Nothing may spawn afterwards —
    /// a child spawned post-terminate would be orphaned by app exit (§6) or
    /// race a replacement runner in the same vault (§2.4).
    case shuttingDown
}

/// What a finished successful run yielded.
public struct RunSummary: Sendable, Equatable {
    public let sessionID: String?
    public let editedFiles: [String]
    public let durationMS: Int?
    public let numTurns: Int?
    public let resultText: String?

    public init(
        sessionID: String?,
        editedFiles: [String],
        durationMS: Int?,
        numTurns: Int?,
        resultText: String?
    ) {
        self.sessionID = sessionID
        self.editedFiles = editedFiles
        self.durationMS = durationMS
        self.numTurns = numTurns
        self.resultText = resultText
    }
}

/// Why and how a run failed. `sessionID` (when the stream got far enough to
/// carry one) powers the terminal escape hatch.
public struct RunFailure: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case nonZeroExit(Int32)
        case timeout
        /// Exit 0 but no `result` event ever arrived.
        case malformedStream
        /// Exit 0 but the result event reported an error (`is_error` true or
        /// `subtype` ≠ "success", e.g. "error_max_turns").
        case errorResult(subtype: String?)
        case spawnFailed(String)
    }

    public let reason: Reason
    /// Last 3 stderr lines (from a 50-line ring buffer).
    public let stderrTail: [String]
    public let sessionID: String?

    public init(reason: Reason, stderrTail: [String], sessionID: String?) {
        self.reason = reason
        self.stderrTail = stderrTail
        self.sessionID = sessionID
    }
}

public enum RunOutcome: Sendable, Equatable {
    case success(RunSummary)
    case failure(RunFailure)
}

public struct RunCompletion: Sendable, Equatable {
    public let handle: RunHandle
    public let outcome: RunOutcome

    public init(handle: RunHandle, outcome: RunOutcome) {
        self.handle = handle
        self.outcome = outcome
    }
}

/// Surfaced via `ClaudeRunner.events` for the App layer (island transitions,
/// peeks, queue bookkeeping).
public enum RunnerEvent: Sendable, Equatable {
    case runStarted(RunHandle)
    case runCompleted(RunCompletion)
    case queueChanged(depth: Int)
}

// MARK: - Actor

public actor ClaudeRunner {
    /// Injected at init; `extraArgs` deliberately does not exist — the
    /// invocation is never widened (§2.3).
    public struct Configuration: Sendable {
        public var binaryURL: URL
        public var vault: Vault
        /// The parent environment to sanitize and inherit; defaults to this
        /// process's. Every spawn routes it through
        /// `RunEnvironment.sanitizedEnvironment` (§2.2).
        public var environment: [String: String]
        /// Wall-clock timeout before SIGTERM (120 s per §6; injectable).
        public var timeout: TimeInterval
        /// SIGTERM → SIGKILL grace (5 s per §6; injectable).
        public var killGracePeriod: TimeInterval

        public init(
            binaryURL: URL,
            vault: Vault,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            timeout: TimeInterval = 120,
            killGracePeriod: TimeInterval = 5
        ) {
            self.binaryURL = binaryURL
            self.vault = vault
            self.environment = environment
            self.timeout = timeout
            self.killGracePeriod = killGracePeriod
        }
    }

    /// Queue cap: one live run plus at most 5 pending (§6).
    static let maxPending = 5

    /// Runner lifecycle events; the App layer consumes this single stream.
    public nonisolated let events: AsyncStream<RunnerEvent>

    /// Shutdown bookkeeping shared with nonisolated contexts: lets
    /// `terminateNow()` SIGTERM the live child synchronously from the
    /// main-thread quit path (no semaphore, no actor hop), and gates
    /// enqueue/spawn once shutdown began so no child can be spawned AFTER a
    /// terminate — it would be orphaned at app exit or race a replacement
    /// runner in the same vault.
    private struct ChildState: Sendable {
        var livePID: pid_t?
        var isShuttingDown = false
    }

    private let configuration: Configuration
    private let eventContinuation: AsyncStream<RunnerEvent>.Continuation
    private let childState = OSAllocatedUnfairLock(initialState: ChildState())
    private var pending: [PendingRun] = []
    private var isProcessing = false
    private var liveProcess: Process?
    /// Kept (dead) after completion so tests can assert the child really died.
    private var lastSpawnedProcess: Process?
    private var parser = StreamParser()
    private var stderrLines = RingLineBuffer(capacity: 50)
    private var currentTimedOut = false
    private let logger = Logger(subsystem: "app.ledge", category: "runner")

    public init(configuration: Configuration) {
        self.configuration = configuration
        (events, eventContinuation) = AsyncStream.makeStream(of: RunnerEvent.self)
    }

    // MARK: - API

    /// FIFO enqueue. `resumeSessionID` is plumbing for the Phase-4
    /// "continue last session" toggle; default nil = fresh session (§6).
    public func enqueue(prompt: String, resumeSessionID: String? = nil) -> Enqueued {
        guard !isShuttingDown else {
            logger.error("enqueue rejected: runner is shutting down")
            return .rejected(reason: .shuttingDown)
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.binaryURL.path) else {
            logger.error("enqueue rejected: binary not executable")
            return .rejected(reason: .noBinary)
        }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: configuration.vault.root.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            logger.error("enqueue rejected: vault invalid")
            return .rejected(reason: .invalidVault)
        }

        let run = PendingRun(handle: RunHandle(prompt: prompt), resumeSessionID: resumeSessionID)
        if isProcessing {
            guard pending.count < Self.maxPending else {
                logger.error("enqueue rejected: queue full (\(Self.maxPending) pending)")
                return .rejected(reason: .queueFull)
            }
            pending.append(run)
            emit(.queueChanged(depth: pending.count))
            return .queued(run.handle, position: pending.count)
        }
        isProcessing = true
        startWorker(with: run)
        return .started(run.handle)
    }

    /// Runner retirement / app quit (§6): stop accepting work, drop every
    /// queued run, SIGTERM the live child, escalate to SIGKILL after the
    /// configured grace period, and return only once the child has actually
    /// exited. The wait matters: a caller may immediately spawn a replacement
    /// runner in the SAME vault, and §2.4 (one live run per vault) forbids the
    /// old child overlapping the new one. Terminal — later enqueues are
    /// rejected with `.shuttingDown`.
    public func terminateAll() async {
        childState.withLock { $0.isShuttingDown = true }
        if !pending.isEmpty {
            pending.removeAll()
            emit(.queueChanged(depth: 0))
        }
        guard let process = liveProcess, process.isRunning else { return }
        logger.info("terminateAll: SIGTERM live child")
        process.terminate()
        await waitForExit(of: process, upTo: configuration.killGracePeriod)
        if process.isRunning {
            logger.error("terminateAll: child survived SIGTERM — SIGKILL")
            kill(process.processIdentifier, SIGKILL)
            await waitForExit(of: process, upTo: 2)
        }
    }

    /// Synchronous, nonisolated quit primitive: marks the runner as shutting
    /// down (no further spawns) and SIGTERMs the live child without waiting.
    /// Safe to call from `applicationWillTerminate` on the main thread — no
    /// semaphore, no actor hop, the signal is sent before this returns.
    public nonisolated func terminateNow() {
        let livePID: pid_t? = childState.withLock { state in
            state.isShuttingDown = true
            return state.livePID
        }
        if let livePID {
            kill(livePID, SIGTERM)
        }
    }

    private nonisolated var isShuttingDown: Bool {
        childState.withLock { $0.isShuttingDown }
    }

    private func waitForExit(of process: Process, upTo seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The exact argv (after the binary path). Public so tests pin it —
    /// `--verbose` is REQUIRED with print-mode stream-json (live-probe
    /// finding) and the tool list is exactly §2.3's.
    public static func arguments(prompt: String, resumeSessionID: String?) -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--allowedTools", "Read,Write,Edit,Glob,Grep",
            "--permission-mode", "acceptEdits",
            "--max-turns", "6",
        ]
        if let resumeSessionID {
            args += ["--resume", resumeSessionID]
        }
        return args
    }

    /// Test hook: is the most recently spawned child still alive?
    func lastChildIsRunningForTesting() -> Bool {
        lastSpawnedProcess?.isRunning ?? false
    }

    // MARK: - Worker loop (serialized FIFO)

    private struct PendingRun: Sendable {
        let handle: RunHandle
        let resumeSessionID: String?
    }

    private func startWorker(with first: PendingRun) {
        Task {
            var current: PendingRun? = first
            while let run = current {
                // Re-checked every iteration: terminateAll/terminateNow may
                // have raced a dequeued-but-not-yet-spawned run — spawning
                // after a terminate would orphan the child (§6).
                guard !isShuttingDown else { break }
                emit(.runStarted(run.handle))
                let completion = await execute(run)
                emit(.runCompleted(completion))
                current = dequeueNext()
            }
            isProcessing = false
        }
    }

    private func dequeueNext() -> PendingRun? {
        guard !pending.isEmpty else {
            isProcessing = false
            return nil
        }
        let next = pending.removeFirst()
        emit(.queueChanged(depth: pending.count))
        return next
    }

    private func emit(_ event: RunnerEvent) {
        eventContinuation.yield(event)
    }

    // MARK: - One run

    private func execute(_ run: PendingRun) async -> RunCompletion {
        // Belt-and-braces re-check (the worker loop already gates): never
        // spawn once shutdown began.
        guard !isShuttingDown else {
            return RunCompletion(
                handle: run.handle,
                outcome: .failure(RunFailure(
                    reason: .spawnFailed("runner is shutting down"),
                    stderrTail: [],
                    sessionID: nil
                ))
            )
        }
        parser = StreamParser()
        stderrLines = RingLineBuffer(capacity: 50)
        currentTimedOut = false

        let process = Process()
        process.executableURL = configuration.binaryURL
        process.arguments = Self.arguments(
            prompt: run.handle.prompt,
            resumeSessionID: run.resumeSessionID
        )
        process.currentDirectoryURL = configuration.vault.root // §2.5, never ~ or /
        // Live-probe finding: without an attached stdin the CLI stalls ~3 s
        // warning about missing stdin.
        process.standardInput = FileHandle.nullDevice
        process.environment = RunEnvironment.sanitizedEnvironment(configuration.environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (stdoutChunks, stdoutContinuation) = Self.chunkStream(
            reading: stdoutPipe.fileHandleForReading
        )
        let (stderrChunks, stderrContinuation) = Self.chunkStream(
            reading: stderrPipe.fileHandleForReading
        )
        let (exitEvents, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutContinuation.finish()
            stderrContinuation.finish()
            exitContinuation.finish()
            logger.error("spawn failed: \(error.localizedDescription, privacy: .public)")
            return RunCompletion(
                handle: run.handle,
                outcome: .failure(RunFailure(
                    reason: .spawnFailed(error.localizedDescription),
                    stderrTail: [],
                    sessionID: nil
                ))
            )
        }
        liveProcess = process
        lastSpawnedProcess = process
        // No suspension point since the isShuttingDown check above, so a
        // terminate cannot have slipped in between; from here on terminateNow
        // sees the pid. (A terminateAll interleaving at a later await finds
        // `liveProcess` set and SIGTERMs it directly.)
        childState.withLock { $0.livePID = process.processIdentifier }
        logger.info("spawned claude pid \(process.processIdentifier)")

        // Drain both pipes (actor-isolated tasks; the readability handlers
        // keep the pipes empty regardless of when these consume).
        let stdoutTask = Task {
            for await chunk in stdoutChunks {
                parser.feed(chunk)
            }
            parser.finish()
        }
        let stderrTask = Task {
            for await chunk in stderrChunks {
                stderrLines.feed(chunk)
            }
            stderrLines.finish()
        }

        // Wall-clock timeout: SIGTERM, then SIGKILL after the grace period.
        let timeoutTask = Task { [timeout = configuration.timeout,
                                  grace = configuration.killGracePeriod] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, process.isRunning else { return }
                currentTimedOut = true
                logger.error("run timed out after \(timeout, privacy: .public)s — SIGTERM")
                process.terminate()
                try? await Task.sleep(for: .seconds(grace))
                guard !Task.isCancelled, process.isRunning else { return }
                logger.error("child survived SIGTERM — SIGKILL")
                kill(process.processIdentifier, SIGKILL)
        }

        var exitStatus: Int32 = -1
        for await status in exitEvents {
            exitStatus = status
        }
        timeoutTask.cancel()

        // The child is dead, but an orphaned grandchild (e.g. a `sleep` left
        // behind by a SIGTERMed shell) can hold the pipe write ends open
        // indefinitely — bound the wait for EOF, then force-finish.
        let eofGuard = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutContinuation.finish()
            stderrContinuation.finish()
        }
        await stdoutTask.value
        await stderrTask.value
        eofGuard.cancel()
        liveProcess = nil
        childState.withLock { $0.livePID = nil }

        return RunCompletion(handle: run.handle, outcome: outcome(exitStatus: exitStatus))
    }

    private func outcome(exitStatus: Int32) -> RunOutcome {
        let sessionID = parser.sessionID ?? parser.result?.sessionID
        let tail = stderrLines.tail(3)
        if currentTimedOut {
            return .failure(RunFailure(reason: .timeout, stderrTail: tail, sessionID: sessionID))
        }
        if exitStatus != 0 {
            return .failure(RunFailure(
                reason: .nonZeroExit(exitStatus),
                stderrTail: tail,
                sessionID: sessionID
            ))
        }
        guard let result = parser.result else {
            // Exit 0 but no result event: malformed stream (§ decision 5).
            return .failure(RunFailure(
                reason: .malformedStream,
                stderrTail: tail,
                sessionID: sessionID
            ))
        }
        guard !result.isError else {
            // The CLI reported an error result yet exited 0 (e.g. a
            // subtype like "error_max_turns"). Surface the CLI-reported
            // cause — NOT a bogus "exit 0" — while keeping the resume
            // escape hatch.
            return .failure(RunFailure(
                reason: .errorResult(subtype: result.subtype),
                stderrTail: tail,
                sessionID: sessionID
            ))
        }
        return .success(RunSummary(
            sessionID: result.sessionID ?? parser.sessionID,
            editedFiles: parser.editedFiles,
            durationMS: result.durationMS,
            numTurns: result.numTurns,
            resultText: result.resultText
        ))
    }

    /// Bridges a pipe's readability handler into an AsyncStream of chunks.
    /// The handler runs on an arbitrary thread and touches ONLY the (Sendable)
    /// continuation; EOF finishes the stream and disarms the handler.
    private static func chunkStream(
        reading handle: FileHandle
    ) -> (AsyncStream<Data>, AsyncStream<Data>.Continuation) {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        return (stream, continuation)
    }
}

// MARK: - Stderr ring buffer

/// Keeps the last `capacity` stderr lines (spec: ~50); `tail(3)` feeds the
/// failure peek.
struct RingLineBuffer: Sendable {
    private(set) var lines: [String] = []
    private var partial = Data()
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func feed(_ data: Data) {
        partial.append(data)
        while let newlineIndex = partial.firstIndex(of: 0x0A) {
            let line = partial.subdata(in: partial.startIndex ..< newlineIndex)
            partial = partial.subdata(in: partial.index(after: newlineIndex) ..< partial.endIndex)
            append(line: line)
        }
    }

    mutating func finish() {
        if !partial.isEmpty {
            append(line: partial)
            partial.removeAll()
        }
    }

    func tail(_ count: Int) -> [String] {
        Array(lines.suffix(count))
    }

    private mutating func append(line: Data) {
        var line = line
        if line.last == 0x0D {
            line = line.dropLast()
        }
        lines.append(String(decoding: line, as: UTF8.self))
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }
}
