@testable import LedgeCore
import XCTest

/// §6 stream parser against BOTH fixtures: the real CLI's captured stream
/// (Tests/fixtures/live-probe.ndjson, claude 2.1.226) and live fake-claude.sh
/// output for every mode — plus chunk-boundary torture and malformed input.
final class StreamParserTests: XCTestCase {
    // MARK: - live-probe.ndjson (observed reality)

    private func liveProbeData() throws -> Data {
        try Data(contentsOf: Fixtures.liveProbe)
    }

    private func assertLiveProbeExtraction(_ parser: StreamParser, feeding: String) {
        XCTAssertEqual(
            parser.sessionID, "28c4ffe9-257b-472c-b034-2c3d3e638ca0",
            "\(feeding): wrong sessionID"
        )
        XCTAssertEqual(parser.transcript, ["ok"], feeding)
        XCTAssertEqual(parser.editedFiles, [], feeding)
        XCTAssertEqual(parser.malformedLineCount, 0, "\(feeding): unknown events must be skipped silently")
        let result = parser.result
        XCTAssertNotNil(result, feeding)
        XCTAssertEqual(result?.sessionID, "28c4ffe9-257b-472c-b034-2c3d3e638ca0", feeding)
        XCTAssertEqual(result?.isError, false, feeding)
        XCTAssertEqual(result?.subtype, "success", feeding)
        XCTAssertEqual(result?.durationMS, 3002, feeding)
        XCTAssertEqual(result?.numTurns, 1, feeding)
        XCTAssertEqual(result?.resultText, "ok", feeding)
        XCTAssertEqual(result?.totalCostUSD ?? 0, 0.176463, accuracy: 0.000001, feeding)
    }

    func testLiveProbeWholeFeed() throws {
        var parser = StreamParser()
        try parser.feed(liveProbeData())
        parser.finish()
        assertLiveProbeExtraction(parser, feeding: "whole")
    }

    /// Chunk-boundary torture: byte-by-byte and odd-sized chunks must yield
    /// exactly the same outcome as one whole feed.
    func testLiveProbeByteByByte() throws {
        var parser = StreamParser()
        for byte in try liveProbeData() {
            parser.feed(Data([byte]))
        }
        parser.finish()
        assertLiveProbeExtraction(parser, feeding: "byte-by-byte")
    }

    func testLiveProbeSplitChunks() throws {
        let data = try liveProbeData()
        for chunkSize in [7, 64, 1000] {
            var parser = StreamParser()
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(data.index(start, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex, data.endIndex)
                parser.feed(data.subdata(in: start ..< end))
                start = end
            }
            parser.finish()
            assertLiveProbeExtraction(parser, feeding: "chunks of \(chunkSize)")
        }
    }

    // MARK: - fake-claude.sh live output, every mode

    /// Runs the actual fixture script (never the real CLI) and returns stdout.
    private func fakeClaudeStdout(mode: String, extraEnv: [String: String] = [:]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Fixtures.fakeClaude.path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env["FAKE_CLAUDE_MODE"] = mode
        for (key, value) in extraEnv {
            env[key] = value
        }
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private func parse(_ data: Data) -> StreamParser {
        var parser = StreamParser()
        parser.feed(data)
        parser.finish()
        return parser
    }

    func testFakeSuccessMode() throws {
        let parser = try parse(fakeClaudeStdout(mode: "success"))
        XCTAssertEqual(parser.sessionID?.hasPrefix("fake-session-"), true)
        XCTAssertEqual(parser.transcript, ["Done. Appended the task to today's daily note."])
        XCTAssertEqual(parser.editedFiles, [])
        XCTAssertEqual(parser.malformedLineCount, 0)
        XCTAssertEqual(parser.result?.isError, false)
        XCTAssertEqual(parser.result?.durationMS, 1234)
        XCTAssertEqual(parser.result?.numTurns, 1)
        XCTAssertEqual(parser.result?.resultText, "Done. Appended the task to today's daily note.")
    }

    /// 3 Write/Edit tool_use blocks over 2 unique paths → ordered de-dup.
    func testFakeEditsMode() throws {
        let parser = try parse(fakeClaudeStdout(mode: "edits"))
        XCTAssertEqual(parser.editedFiles, ["daily/2026-08-08.md", "notes/new-note.md"])
        XCTAssertEqual(parser.transcript, ["Edited two files."])
        XCTAssertEqual(parser.result?.numTurns, 4)
        XCTAssertEqual(parser.malformedLineCount, 0)
    }

    /// Failure mode writes only to stderr after init: parser sees init, no result.
    func testFakeFailureMode() throws {
        let parser = try parse(fakeClaudeStdout(mode: "failure"))
        XCTAssertEqual(parser.sessionID?.hasPrefix("fake-session-"), true)
        XCTAssertNil(parser.result)
        XCTAssertEqual(parser.malformedLineCount, 0)
    }

    /// Garbage mode: every line is a non-object — counted, never fatal.
    func testFakeGarbageMode() throws {
        let parser = try parse(fakeClaudeStdout(mode: "garbage"))
        XCTAssertNil(parser.sessionID)
        XCTAssertNil(parser.result)
        XCTAssertEqual(parser.malformedLineCount, 3)
    }

    func testFakeSlowMode() throws {
        let parser = try parse(fakeClaudeStdout(mode: "slow", extraEnv: ["FAKE_CLAUDE_SLEEP": "0"]))
        XCTAssertEqual(parser.result?.resultText, "finally done")
        XCTAssertEqual(parser.result?.isError, false)
    }

    func testFakeEnvcheckMode() throws {
        let parser = try parse(fakeClaudeStdout(mode: "envcheck"))
        XCTAssertEqual(parser.result?.isError, false)
        XCTAssertEqual(parser.result?.resultText, "Done. Appended the task to today's daily note.")
    }

    /// Error result on a zero exit: isError set, subtype preserved for the
    /// failure peek.
    func testFakeErrorResultMode() throws {
        let parser = try parse(fakeClaudeStdout(mode: "errorresult"))
        XCTAssertEqual(parser.result?.isError, true)
        XCTAssertEqual(parser.result?.subtype, "error_max_turns")
        XCTAssertEqual(parser.malformedLineCount, 0)
    }

    // MARK: - Tolerance details

    func testResultSubtypeOtherThanSuccessIsError() {
        var parser = StreamParser()
        parser.feed(Data("""
        {"type":"result","subtype":"error_max_turns","is_error":false,"session_id":"s","duration_ms":1,"num_turns":6,"result":"nope"}\n
        """.utf8))
        XCTAssertEqual(parser.result?.isError, true)
    }

    func testIsErrorFlagAloneMarksError() {
        var parser = StreamParser()
        parser.feed(Data("""
        {"type":"result","subtype":"success","is_error":true,"session_id":"s"}\n
        """.utf8))
        XCTAssertEqual(parser.result?.isError, true)
    }

    func testNonWriteEditToolUseIgnored() {
        var parser = StreamParser()
        parser.feed(Data("""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"a.md"}},{"type":"tool_use","name":"Glob","input":{"file_path":"b.md"}}]}}\n
        """.utf8))
        XCTAssertEqual(parser.editedFiles, [])
    }

    func testCRLFAndBlankLinesTolerated() {
        var parser = StreamParser()
        parser.feed(Data("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"crlf\"}\r\n\r\n   \n".utf8))
        parser.finish()
        XCTAssertEqual(parser.sessionID, "crlf")
        XCTAssertEqual(parser.malformedLineCount, 0)
    }

    func testFinishFlushesUnterminatedFinalLine() {
        var parser = StreamParser()
        parser.feed(Data("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"tail\"}".utf8))
        XCTAssertNil(parser.sessionID, "line without newline must stay buffered")
        parser.finish()
        XCTAssertEqual(parser.sessionID, "tail")
    }
}
