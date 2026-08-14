@testable import LedgeCore
import XCTest

/// The whole reply→vault path (§2.3). This is what AgentRunController calls,
/// so every branch it can show the user is pinned here rather than in the
/// untested App layer.
final class PlanApplicationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = try Fixtures.makeTempVaultCopy()
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    private func vault() throws -> Vault {
        try Vault(root: tempRoot)
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: tempRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func apply(_ message: String?) throws -> PlanApplication.Outcome {
        try PlanApplication.apply(finalMessage: message, in: vault())
    }

    // MARK: - The happy path

    func testAppliesAPlanFromAReplyWithProse() throws {
        let message = """
        I looked through the vault; this belongs in today's daily note.

        ```json
        {"edits":[{"op":"create","path":"notes/sam.md","content":"# Sam\\n"}]}
        ```
        """
        guard case let .applied(result) = try apply(message) else {
            return XCTFail("expected applied")
        }
        XCTAssertEqual(result.filesChanged.map(\.lastPathComponent), ["sam.md"])
        XCTAssertEqual(try read("notes/sam.md"), "# Sam\n")
    }

    /// The real captured CLI reply, end to end.
    func testAppliesTheRealCLIReply() throws {
        let message = try String(contentsOf: Fixtures.livePlanMessage, encoding: .utf8)
        // The fixture's plan appends to daily/2026-08-14.md, which the fixture
        // vault does not have — create it so the append has a target.
        let daily = tempRoot.appendingPathComponent("daily/2026-08-14.md")
        try Data("# 2026-08-14\n".utf8).write(to: daily)

        guard case let .applied(result) = try apply(message) else {
            return XCTFail("expected applied")
        }
        XCTAssertEqual(result.filesChanged.count, 1)
        XCTAssertEqual(
            try read("daily/2026-08-14.md"),
            "# 2026-08-14\n- 09:15Z Met Sam about the kickoff\n"
        )
    }

    // MARK: - Nothing to change

    func testEmptyPlanIsNothingToChangeNotAFailure() throws {
        guard case .nothingToChange = try apply(#"{"edits":[]}"#) else {
            return XCTFail("an empty plan is a real answer")
        }
    }

    // MARK: - Refusals

    func testNoReplyIsRefused() throws {
        guard case let .refused(reason) = try apply(nil) else { return XCTFail("expected refused") }
        XCTAssertTrue(reason.contains("without a reply"))

        guard case .refused = try apply("   \n  ") else { return XCTFail("expected refused") }
    }

    func testReplyWithoutAPlanIsRefusedAndSaysSo() throws {
        guard case let .refused(reason) = try apply("I couldn't work out where this goes.") else {
            return XCTFail("expected refused")
        }
        XCTAssertEqual(reason, EditPlanExtractionError.noJSONFound.errorDescription)
    }

    /// The fence reaches all the way out to this call — an escaping path is
    /// refused with a reason the peek can show verbatim.
    func testEscapingPathIsRefusedWithAReadableReason() throws {
        let message = #"{"edits":[{"op":"create","path":"../../escape.md","content":"x"}]}"#
        guard case let .refused(reason) = try apply(message) else {
            return XCTFail("expected refused")
        }
        XCTAssertTrue(reason.contains("climbs out of the vault"), reason)
    }

    func testDotClaudePathIsRefused() throws {
        let message = #"{"edits":[{"op":"create","path":".claude/commands/evil.md","content":"x"}]}"#
        guard case let .refused(reason) = try apply(message) else {
            return XCTFail("expected refused")
        }
        XCTAssertTrue(reason.contains("Hidden") || reason.contains("hidden"), reason)
    }

    /// A refused plan must leave the vault exactly as it was — the refusal
    /// happens before anything is written, and the good edit in the same plan
    /// goes with it.
    func testARefusedPlanWritesNothingAtAll() throws {
        let message = """
        {"edits":[
          {"op":"create","path":"notes/good.md","content":"# Good\\n"},
          {"op":"create","path":"/etc/passwd.md","content":"bad"}
        ]}
        """
        guard case .refused = try apply(message) else { return XCTFail("expected refused") }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("notes/good.md").path
            ),
            "no edit lands when any edit is refused"
        )
    }

    func testMissingTargetFileIsRefusedWithAReadableReason() throws {
        let message = #"{"edits":[{"op":"append","path":"notes/ghost.md","text":"x"}]}"#
        guard case let .refused(reason) = try apply(message) else {
            return XCTFail("expected refused")
        }
        XCTAssertTrue(reason.contains("does not exist"), reason)
    }
}
