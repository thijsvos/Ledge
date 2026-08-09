import LedgeCore
import XCTest

/// RunHistoryStore: append/read round-trip, corrupt-line tolerance, vault
/// filtering, newest-first ordering + limit, compaction, missing file,
/// unicode prompts, excerpt truncation. Everything runs against a fresh temp
/// directory — the store's parent-directory creation is exercised by using a
/// nested path that never exists beforehand.
final class RunHistoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-history-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Deliberately nested so `append` must create intermediate directories.
    private var fileURL: URL {
        tempDir
            .appendingPathComponent("Ledge", isDirectory: true)
            .appendingPathComponent("run-history.jsonl", isDirectory: false)
    }

    private func makeStore() -> RunHistoryStore {
        RunHistoryStore(fileURL: fileURL)
    }

    private func makeRecord(
        prompt: String = "summarize inbox",
        vaultPath: String = "/tmp/vault",
        sessionID: String? = "sess-1234-abcd",
        outcome: RunRecord.Outcome = .success,
        date: Date = Date(timeIntervalSinceReferenceDate: 777_000_000.125),
        editedFiles: [String] = ["daily/2026-08-08.md"],
        durationMS: Int? = 1234,
        resultExcerpt: String? = "Done.",
        stderrTail: [String] = []
    ) -> RunRecord {
        RunRecord(
            id: UUID(),
            date: date,
            vaultPath: vaultPath,
            prompt: prompt,
            sessionID: sessionID,
            outcome: outcome,
            editedFiles: editedFiles,
            durationMS: durationMS,
            resultExcerpt: resultExcerpt,
            stderrTail: stderrTail
        )
    }

    private func rawLines() throws -> [String] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return contents.split(separator: "\n").map(String.init)
    }

    // MARK: - Round trip

    func testAppendReadRoundTripAllOutcomes() throws {
        let store = makeStore()
        let success = makeRecord(prompt: "a success")
        let failure = makeRecord(
            prompt: "a failure",
            sessionID: nil,
            outcome: .failure(reason: "Run failed (exit 1)"),
            editedFiles: [],
            durationMS: nil,
            resultExcerpt: nil,
            stderrTail: ["Error: boom", "Giving up"]
        )
        let cancelled = makeRecord(
            prompt: "a cancelled run",
            outcome: .cancelled,
            editedFiles: [],
            durationMS: nil,
            resultExcerpt: nil
        )
        try store.append(success)
        try store.append(failure)
        try store.append(cancelled)

        let loaded = store.recentRuns(vaultPath: "/tmp/vault")
        // Newest first: reverse append order, every field intact.
        XCTAssertEqual(loaded, [cancelled, failure, success])
    }

    func testAppendCreatesParentDirectories() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        try makeStore().append(makeRecord())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEachRecordIsOneJSONLine() throws {
        let store = makeStore()
        // Prompts with newlines must still occupy exactly one line (JSON
        // escapes them).
        try store.append(makeRecord(prompt: "line one\nline two"))
        try store.append(makeRecord(prompt: "second"))
        XCTAssertEqual(try rawLines().count, 2)
    }

    // MARK: - Missing / corrupt input

    func testMissingFileReturnsEmpty() {
        XCTAssertEqual(makeStore().recentRuns(vaultPath: "/tmp/vault"), [])
    }

    func testCorruptAndUnknownLinesAreSkippedNeverThrown() throws {
        let store = makeStore()
        let good = makeRecord(prompt: "good one")
        try store.append(good)

        // Sabotage the file with everything recentRuns must tolerate.
        var contents = try String(contentsOf: fileURL, encoding: .utf8)
        contents += "this is not json at all\n"
        contents += "{\"id\": 12}\n" // wrong shape
        contents += "{}\n" // missing every field
        contents += "42\n" // JSON, not an object
        contents += "\n" // blank line
        // A future record with an unknown outcome case: skipped whole.
        contents += """
        {"id":"9C4B4C1E-0000-0000-0000-000000000000",\
        "date":0,"vaultPath":"/tmp/vault","prompt":"future",\
        "sessionID":null,"outcome":{"paused":{}},"editedFiles":[],\
        "durationMS":null,"resultExcerpt":null,"stderrTail":[]}\n
        """
        try Data(contents.utf8).write(to: fileURL)

        let good2 = makeRecord(prompt: "good two")
        try store.append(good2)

        XCTAssertEqual(store.recentRuns(vaultPath: "/tmp/vault"), [good2, good])
    }

    func testUnknownFutureFieldsOnAValidRecordAreIgnored() throws {
        let store = makeStore()
        let record = makeRecord(prompt: "with future field")
        try store.append(record)

        // Inject an unknown key into the stored line: still decodes.
        var contents = try String(contentsOf: fileURL, encoding: .utf8)
        contents = contents.replacingOccurrences(
            of: "{\"date\"",
            with: "{\"someFutureField\":true,\"date\""
        )
        try Data(contents.utf8).write(to: fileURL)

        XCTAssertEqual(store.recentRuns(vaultPath: "/tmp/vault"), [record])
    }

    // MARK: - Filtering, ordering, limit

    func testVaultFiltering() throws {
        let store = makeStore()
        let vaultA = makeRecord(prompt: "for A", vaultPath: "/vault/a")
        let vaultB = makeRecord(prompt: "for B", vaultPath: "/vault/b")
        let vaultA2 = makeRecord(prompt: "for A again", vaultPath: "/vault/a")
        try store.append(vaultA)
        try store.append(vaultB)
        try store.append(vaultA2)

        XCTAssertEqual(store.recentRuns(vaultPath: "/vault/a"), [vaultA2, vaultA])
        XCTAssertEqual(store.recentRuns(vaultPath: "/vault/b"), [vaultB])
        XCTAssertEqual(store.recentRuns(vaultPath: "/vault/c"), [])
    }

    func testOrderingIsNewestFirstAndLimitKeepsTheNewest() throws {
        let store = makeStore()
        let records = (1 ... 5).map { makeRecord(prompt: "run \($0)") }
        for record in records {
            try store.append(record)
        }
        XCTAssertEqual(
            store.recentRuns(vaultPath: "/tmp/vault").map(\.prompt),
            ["run 5", "run 4", "run 3", "run 2", "run 1"]
        )
        XCTAssertEqual(
            store.recentRuns(vaultPath: "/tmp/vault", limit: 2).map(\.prompt),
            ["run 5", "run 4"]
        )
    }

    // MARK: - Compaction

    func testCompactionRewritesKeepingNewestWhenOverTwiceMax() throws {
        let store = makeStore()
        for index in 1 ... 7 {
            try store.append(makeRecord(prompt: "run \(index)"))
        }
        store.compactIfNeeded(maxRecords: 3) // 7 > 6 → keep newest 3
        XCTAssertEqual(try rawLines().count, 3)
        XCTAssertEqual(
            store.recentRuns(vaultPath: "/tmp/vault").map(\.prompt),
            ["run 7", "run 6", "run 5"]
        )
    }

    func testCompactionIsANoOpAtOrBelowTwiceMax() throws {
        let store = makeStore()
        for index in 1 ... 6 {
            try store.append(makeRecord(prompt: "run \(index)"))
        }
        store.compactIfNeeded(maxRecords: 3) // 6 == 2×3 → untouched
        XCTAssertEqual(try rawLines().count, 6)
    }

    func testCompactionOnMissingFileIsHarmless() {
        makeStore().compactIfNeeded(maxRecords: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Torn-tail healing

    /// A mid-record write failure (e.g. ENOSPC after a partial write) leaves
    /// a newline-less fragment at the end of the file. The next append must
    /// not concatenate onto it — that would corrupt the NEW record too — but
    /// terminate the torn tail and write itself on a fresh line.
    func testTornTailIsHealedSoTheNextAppendSurvives() throws {
        let store = makeStore()
        let first = makeRecord(prompt: "first")
        try store.append(first)

        // Simulate the torn tail: a partial record with no trailing newline.
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"torn".utf8))
        try handle.close()

        let second = makeRecord(prompt: "second")
        try store.append(second)

        // The fragment became its own (skipped) line; both real records read.
        XCTAssertEqual(store.recentRuns(vaultPath: "/tmp/vault"), [second, first])
        XCTAssertEqual(try rawLines().count, 3)
    }

    func testAppendAfterACleanTailAddsNoBlankLine() throws {
        let store = makeStore()
        try store.append(makeRecord(prompt: "one"))
        try store.append(makeRecord(prompt: "two"))
        let data = try Data(contentsOf: fileURL)
        // Whole-line records, no doubled newlines anywhere.
        XCTAssertNil(data.range(of: Data([0x0A, 0x0A])))
        XCTAssertEqual(try rawLines().count, 2)
    }

    // MARK: - Content edge cases

    func testUnicodePromptsRoundTrip() throws {
        let store = makeStore()
        let record = makeRecord(prompt: "整理する 📝 café naïve — ‘quotes’ \\ \"json\"")
        try store.append(record)
        XCTAssertEqual(store.recentRuns(vaultPath: "/tmp/vault"), [record])
    }

    func testResultExcerptIsTruncatedTo500Characters() {
        let long = String(repeating: "x", count: 800)
        let record = makeRecord(resultExcerpt: long)
        XCTAssertEqual(record.resultExcerpt?.count, RunRecord.maxResultExcerptLength)
        XCTAssertEqual(record.resultExcerpt, String(long.prefix(500)))
        // Short excerpts and nil pass through untouched.
        XCTAssertEqual(makeRecord(resultExcerpt: "short").resultExcerpt, "short")
        XCTAssertNil(makeRecord(resultExcerpt: nil).resultExcerpt)
    }
}
