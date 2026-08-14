@testable import LedgeCore
import XCTest

/// Getting the filing slip out of an agent's reply. Models wrap JSON in prose
/// and fences, so these pin the forgiving cases as tightly as the failures.
final class EditPlanExtractorTests: XCTestCase {
    private let onePlan = #"{"edits":[{"op":"append","path":"daily/d.md","text":"- x\n"}]}"#
    private var oneEdit: [EditPlan.Edit] {
        [.append(path: "daily/d.md", text: "- x\n")]
    }

    // MARK: - Shapes that must work

    func testBareJSONObject() throws {
        XCTAssertEqual(try EditPlanExtractor.extract(from: onePlan).edits, oneEdit)
    }

    func testFencedWithLanguageTag() throws {
        let message = "Filed it.\n\n```json\n\(onePlan)\n```"
        XCTAssertEqual(try EditPlanExtractor.extract(from: message).edits, oneEdit)
    }

    func testFencedWithoutLanguageTag() throws {
        let message = "```\n\(onePlan)\n```"
        XCTAssertEqual(try EditPlanExtractor.extract(from: message).edits, oneEdit)
    }

    func testProseBeforeAndAfterTheFence() throws {
        let message = """
        I looked through the vault and this belongs in today's daily note.

        ```json
        \(onePlan)
        ```

        Let me know if you'd rather file it under notes/.
        """
        XCTAssertEqual(try EditPlanExtractor.extract(from: message).edits, oneEdit)
    }

    /// Truncated output is common; an unterminated fence still yields content.
    func testUnterminatedFenceStillYieldsThePlan() throws {
        let message = "Here you go:\n\n```json\n\(onePlan)"
        XCTAssertEqual(try EditPlanExtractor.extract(from: message).edits, oneEdit)
    }

    // MARK: - Choosing between candidates

    /// The contract asks the agent to *end* with the plan, so a later block
    /// beats an earlier one — the earlier is more likely a worked example.
    func testLastFencedBlockWins() throws {
        let first = #"{"edits":[{"op":"append","path":"first.md","text":"1"}]}"#
        let message = "```json\n\(first)\n```\n\nActually, better:\n\n```json\n\(onePlan)\n```"
        XCTAssertEqual(try EditPlanExtractor.extract(from: message).edits, oneEdit)
    }

    /// A fenced block that is not a plan must not shadow a real one in prose.
    func testFallsBackToBareObjectWhenFencedBlockIsNotAPlan() throws {
        let message = "The schema looks like:\n```json\n{\"schema\":true}\n```\nSo: \(onePlan)"
        XCTAssertEqual(try EditPlanExtractor.extract(from: message).edits, oneEdit)
    }

    func testEmptyPlanIsExtractedNotTreatedAsFailure() throws {
        let message = "Nothing to do.\n```json\n{\"edits\":[]}\n```"
        XCTAssertTrue(try EditPlanExtractor.extract(from: message).isEmpty)
    }

    // MARK: - Braces inside strings

    /// Note content routinely contains braces; they must not open or close a
    /// candidate object.
    func testBracesInsideStringContentDoNotBreakScanning() throws {
        let plan = #"{"edits":[{"op":"create","path":"n.md","content":"a } and { b"}]}"#
        XCTAssertEqual(
            try EditPlanExtractor.extract(from: "```json\n\(plan)\n```").edits,
            [.create(path: "n.md", content: "a } and { b")]
        )
    }

    func testEscapedQuotesInsideStringContentDoNotBreakScanning() throws {
        let plan = #"{"edits":[{"op":"create","path":"n.md","content":"say \"hi\" }"}]}"#
        XCTAssertEqual(
            try EditPlanExtractor.extract(from: plan).edits,
            [.create(path: "n.md", content: "say \"hi\" }")]
        )
    }

    // MARK: - Failures

    func testNoJSONAtAll() {
        XCTAssertThrowsError(try EditPlanExtractor.extract(from: "I couldn't find anywhere to file this.")) {
            XCTAssertEqual($0 as? EditPlanExtractionError, .noJSONFound)
        }
    }

    func testEmptyMessage() {
        XCTAssertThrowsError(try EditPlanExtractor.extract(from: "")) {
            XCTAssertEqual($0 as? EditPlanExtractionError, .noJSONFound)
        }
    }

    func testJSONThatIsNotAPlanReportsMalformed() {
        XCTAssertThrowsError(try EditPlanExtractor.extract(from: #"{"result":"ok"}"#)) {
            guard case .malformedJSON = $0 as? EditPlanExtractionError else {
                return XCTFail("expected malformedJSON, got \($0)")
            }
        }
    }

    func testUnknownOperationReportsMalformedWithReason() {
        let plan = #"{"edits":[{"op":"delete","path":"notes/a.md"}]}"#
        XCTAssertThrowsError(try EditPlanExtractor.extract(from: plan)) { error in
            guard case let .malformedJSON(reason) = error as? EditPlanExtractionError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
            XCTAssertTrue(reason.contains("delete"), "reason should name the bad op, got: \(reason)")
        }
    }

    /// Truncated JSON never balances, so there is no candidate at all.
    func testTruncatedJSONReportsNoJSONFound() {
        XCTAssertThrowsError(try EditPlanExtractor.extract(from: #"{"edits":[{"op":"appe"#)) {
            XCTAssertEqual($0 as? EditPlanExtractionError, .noJSONFound)
        }
    }

    // MARK: - Scanner internals

    func testBalancedObjectsFindsNestedAndSequentialObjects() {
        XCTAssertEqual(
            EditPlanExtractor.balancedObjects(in: "a {\"x\":{\"y\":1}} b {\"z\":2} c"),
            ["{\"x\":{\"y\":1}}", "{\"z\":2}"]
        )
    }

    func testBalancedObjectsIgnoresStrayClosingBrace() {
        XCTAssertEqual(EditPlanExtractor.balancedObjects(in: "} {\"a\":1}"), ["{\"a\":1}"])
    }

    func testFencedRegionsReturnsEachFenceInOrder() {
        XCTAssertEqual(
            EditPlanExtractor.fencedRegions(in: "x\n```\nA\n```\ny\n```\nB\n```\nz"),
            ["\nA\n", "\nB\n"]
        )
    }
}
