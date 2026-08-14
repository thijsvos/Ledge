@testable import LedgeCore
import XCTest

/// The filing-slip wire format (§2.3). The agent writes this; Ledge reads it,
/// so decoding is where a hostile or careless plan first meets resistance.
final class EditPlanTests: XCTestCase {
    private func decode(_ json: String) throws -> EditPlan {
        try JSONDecoder().decode(EditPlan.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    func testDecodesAllThreeOperations() throws {
        let plan = try decode("""
        {"edits":[
          {"op":"create","path":"notes/a.md","content":"# A\\n"},
          {"op":"append","path":"daily/2026-08-14.md","text":"- note\\n"},
          {"op":"replace","path":"notes/b.md","find":"old","with":"new"}
        ]}
        """)
        XCTAssertEqual(plan.edits, [
            .create(path: "notes/a.md", content: "# A\n"),
            .append(path: "daily/2026-08-14.md", text: "- note\n"),
            .replace(path: "notes/b.md", find: "old", with: "new"),
        ])
    }

    /// An empty plan is a real answer — "nothing needed changing" — not a
    /// failure, and must not be reported as one.
    func testEmptyPlanDecodes() throws {
        let plan = try decode(#"{"edits":[]}"#)
        XCTAssertTrue(plan.isEmpty)
    }

    func testUnknownOperationIsRejected() {
        XCTAssertThrowsError(try decode(#"{"edits":[{"op":"delete","path":"notes/a.md"}]}"#))
    }

    /// There is no delete operation, by design — spelling it any other way
    /// does not conjure one.
    func testRemoveIsNotAnOperation() {
        XCTAssertThrowsError(try decode(#"{"edits":[{"op":"remove","path":"notes/a.md"}]}"#))
    }

    func testOperationNameIsCaseFolded() throws {
        let plan = try decode(#"{"edits":[{"op":"Append","path":"a.md","text":"x"}]}"#)
        XCTAssertEqual(plan.edits, [.append(path: "a.md", text: "x")])
    }

    func testMissingPayloadFieldIsRejected() {
        XCTAssertThrowsError(try decode(#"{"edits":[{"op":"append","path":"a.md"}]}"#))
        XCTAssertThrowsError(try decode(#"{"edits":[{"op":"replace","path":"a.md","find":"x"}]}"#))
    }

    func testMissingPathIsRejected() {
        XCTAssertThrowsError(try decode(#"{"edits":[{"op":"append","text":"x"}]}"#))
    }

    func testMissingEditsKeyIsRejected() {
        XCTAssertThrowsError(try decode(#"{"plan":[]}"#))
    }

    // MARK: - Round trip

    func testRoundTripsThroughJSON() throws {
        let original = EditPlan(edits: [
            .create(path: "notes/a.md", content: "# A\n"),
            .append(path: "daily/d.md", text: "- x\n"),
            .replace(path: "notes/b.md", find: "old", with: "new"),
        ])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(EditPlan.self, from: data), original)
    }

    // MARK: - Accessors

    func testPathAndOperationNameAccessors() {
        let edits: [EditPlan.Edit] = [
            .create(path: "a.md", content: ""),
            .append(path: "b.md", text: ""),
            .replace(path: "c.md", find: "", with: ""),
        ]
        XCTAssertEqual(edits.map(\.path), ["a.md", "b.md", "c.md"])
        XCTAssertEqual(edits.map(\.operationName), ["create", "append", "replace"])
    }
}
