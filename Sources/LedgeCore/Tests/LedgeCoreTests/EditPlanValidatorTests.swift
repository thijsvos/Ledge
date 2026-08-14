@testable import LedgeCore
import XCTest

/// Checking a filing slip before any of it lands (§2.3). Mutating tests run
/// against a fresh temp copy of the fixture vault.
final class EditPlanValidatorTests: XCTestCase {
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

    private func write(_ contents: String, to relativePath: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func validate(_ edits: [EditPlan.Edit]) throws -> ValidatedPlan {
        try EditPlanValidator.validate(EditPlan(edits: edits), in: vault())
    }

    private func assertRejects(
        _ edits: [EditPlan.Edit],
        _ expected: EditPlanRejection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try validate(edits), file: file, line: line) { error in
            XCTAssertEqual(error as? EditPlanRejection, expected, file: file, line: line)
        }
    }

    // MARK: - create

    func testCreateProducesStepWithNoPriorContents() throws {
        let plan = try validate([.create(path: "notes/new.md", content: "# New\n")])
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertNil(plan.steps[0].before)
        XCTAssertEqual(plan.steps[0].after, "# New\n")
        XCTAssertEqual(plan.bytesWritten, 6)
    }

    func testCreateOverExistingFileIsRefused() throws {
        try write("existing\n", to: "notes/taken.md")
        assertRejects(
            [.create(path: "notes/taken.md", content: "x")],
            .fileExists(index: 0, path: "notes/taken.md")
        )
    }

    // MARK: - append

    func testAppendRepairsMissingTrailingNewline() throws {
        try write("# Day\n- first", to: "notes/a.md")
        let plan = try validate([.append(path: "notes/a.md", text: "- second\n")])
        XCTAssertEqual(plan.steps[0].after, "# Day\n- first\n- second\n")
    }

    func testAppendDoesNotDoubleNewlineWhenFileAlreadyEndsInOne() throws {
        try write("# Day\n", to: "notes/a.md")
        let plan = try validate([.append(path: "notes/a.md", text: "- x\n")])
        XCTAssertEqual(plan.steps[0].after, "# Day\n- x\n")
    }

    func testAppendToEmptyFileAddsNoSeparator() throws {
        try write("", to: "notes/a.md")
        let plan = try validate([.append(path: "notes/a.md", text: "- x\n")])
        XCTAssertEqual(plan.steps[0].after, "- x\n")
    }

    func testAppendToMissingFileIsRefused() {
        assertRejects(
            [.append(path: "notes/ghost.md", text: "x")],
            .fileMissing(index: 0, path: "notes/ghost.md")
        )
    }

    /// Only the appended text counts toward the cap, not the file it lands in.
    func testAppendBytesCountOnlyTheNewMaterial() throws {
        try write(String(repeating: "x", count: 5000) + "\n", to: "notes/big.md")
        let plan = try validate([.append(path: "notes/big.md", text: "- x\n")])
        XCTAssertEqual(plan.bytesWritten, 4)
    }

    // MARK: - replace

    func testReplaceSwapsTheUniqueOccurrence() throws {
        try write("# Index\n## Open\n- a\n", to: "notes/i.md")
        let plan = try validate([
            .replace(path: "notes/i.md", find: "## Open\n", with: "## Open\n- new\n"),
        ])
        XCTAssertEqual(plan.steps[0].after, "# Index\n## Open\n- new\n- a\n")
    }

    func testReplaceRefusesWhenFindIsAbsent() throws {
        try write("# Index\n", to: "notes/i.md")
        assertRejects(
            [.replace(path: "notes/i.md", find: "nope", with: "x")],
            .findNotFound(index: 0, path: "notes/i.md")
        )
    }

    /// The match-exactly-once rule is what stops a replacement landing on the
    /// wrong occurrence.
    func testReplaceRefusesAmbiguousFind() throws {
        try write("- todo\n- todo\n- todo\n", to: "notes/i.md")
        assertRejects(
            [.replace(path: "notes/i.md", find: "- todo\n", with: "- done\n")],
            .findNotUnique(index: 0, path: "notes/i.md", count: 3)
        )
    }

    func testReplaceRefusesEmptyFind() throws {
        try write("# Index\n", to: "notes/i.md")
        assertRejects(
            [.replace(path: "notes/i.md", find: "", with: "x")],
            .emptyFind(index: 0, path: "notes/i.md")
        )
    }

    func testReplaceOnMissingFileIsRefused() {
        assertRejects(
            [.replace(path: "notes/ghost.md", find: "a", with: "b")],
            .fileMissing(index: 0, path: "notes/ghost.md")
        )
    }

    // MARK: - Sequential edits see the projected vault, not the disk

    func testCreateThenAppendToTheSameFileValidates() throws {
        let plan = try validate([
            .create(path: "notes/seq.md", content: "# Seq\n"),
            .append(path: "notes/seq.md", text: "- one\n"),
        ])
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertNil(plan.steps[0].before)
        XCTAssertEqual(plan.steps[1].before, "# Seq\n")
        XCTAssertEqual(plan.steps[1].after, "# Seq\n- one\n")
    }

    func testCreatingTheSameFileTwiceIsRefused() {
        assertRejects(
            [
                .create(path: "notes/dup.md", content: "a"),
                .create(path: "notes/dup.md", content: "b"),
            ],
            .fileExists(index: 1, path: "notes/dup.md")
        )
    }

    func testReplaceSeesTextAnEarlierStepAdded() throws {
        let plan = try validate([
            .create(path: "notes/seq.md", content: "MARKER\n"),
            .replace(path: "notes/seq.md", find: "MARKER", with: "done"),
        ])
        XCTAssertEqual(plan.steps[1].after, "done\n")
    }

    // MARK: - The fence

    func testPathRejectionIsReportedWithItsReason() {
        assertRejects(
            [.create(path: "../escape.md", content: "x")],
            .path(index: 0, path: "../escape.md", reason: .parentTraversal("../escape.md"))
        )
    }

    func testFenceAppliesToEveryEditNotJustTheFirst() {
        assertRejects(
            [
                .create(path: "notes/fine.md", content: "x"),
                .create(path: "/etc/passwd.md", content: "x"),
            ],
            .path(index: 1, path: "/etc/passwd.md", reason: .absolutePath("/etc/passwd.md"))
        )
    }

    // MARK: - Caps

    func testTooManyEditsIsRefused() {
        let edits = (0 ... EditPlanValidator.maxEdits).map {
            EditPlan.Edit.create(path: "notes/n\($0).md", content: "x")
        }
        assertRejects(
            edits,
            .tooManyEdits(count: EditPlanValidator.maxEdits + 1, limit: EditPlanValidator.maxEdits)
        )
    }

    func testExactlyTheEditLimitIsAllowed() throws {
        let edits = (0 ..< EditPlanValidator.maxEdits).map {
            EditPlan.Edit.create(path: "notes/n\($0).md", content: "x")
        }
        XCTAssertEqual(try validate(edits).steps.count, EditPlanValidator.maxEdits)
    }

    func testTooManyBytesIsRefused() {
        let huge = String(repeating: "x", count: EditPlanValidator.maxBytesWritten + 1)
        XCTAssertThrowsError(try validate([.create(path: "notes/huge.md", content: huge)])) { error in
            guard case let .tooLarge(bytes, limit) = error as? EditPlanRejection else {
                return XCTFail("expected tooLarge, got \(error)")
            }
            XCTAssertEqual(bytes, EditPlanValidator.maxBytesWritten + 1)
            XCTAssertEqual(limit, EditPlanValidator.maxBytesWritten)
        }
    }

    /// The cap is on the plan as a whole, not on any single edit.
    func testBytesAccumulateAcrossEdits() {
        let half = String(repeating: "x", count: EditPlanValidator.maxBytesWritten / 2 + 1)
        XCTAssertThrowsError(try validate([
            .create(path: "notes/a.md", content: half),
            .create(path: "notes/b.md", content: half),
        ])) { error in
            guard case .tooLarge = error as? EditPlanRejection else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    // MARK: - Unreadable files

    func testNonUTF8FileIsRefusedRatherThanRewritten() throws {
        let url = tempRoot.appendingPathComponent("notes/binary.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: url)
        XCTAssertThrowsError(try validate([.append(path: "notes/binary.md", text: "x")])) { error in
            guard case .unreadable = error as? EditPlanRejection else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    // MARK: - Empty plan

    func testEmptyPlanValidatesToNoSteps() throws {
        let plan = try validate([])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.bytesWritten, 0)
    }

    // MARK: - Occurrence counting

    func testOccurrenceCountIsNonOverlapping() {
        XCTAssertEqual(EditPlanValidator.occurrenceCount(of: "aa", in: "aaaa"), 2)
        XCTAssertEqual(EditPlanValidator.occurrenceCount(of: "x", in: "abc"), 0)
        XCTAssertEqual(EditPlanValidator.occurrenceCount(of: "", in: "abc"), 0)
    }

    /// Literal matching: two strings that compare equal under canonical
    /// equivalence are not the same bytes, and find/replace is a byte contract.
    func testOccurrenceCountIsLiteralNotCanonical() {
        let precomposed = "é" // U+00E9
        let decomposed = "e\u{0301}" // e + combining acute
        XCTAssertEqual(EditPlanValidator.occurrenceCount(of: precomposed, in: decomposed), 0)
        XCTAssertEqual(EditPlanValidator.occurrenceCount(of: precomposed, in: precomposed), 1)
    }
}
