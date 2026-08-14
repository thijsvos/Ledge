@testable import LedgeCore
import XCTest

/// Writing a checked filing slip (§2.3) — the only place an agent's decision
/// becomes bytes in the vault. All-or-nothing, and never over the top of a
/// concurrent external writer (§1).
final class EditPlanApplierTests: XCTestCase {
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

    private func url(_ relativePath: String) -> URL {
        tempRoot.appendingPathComponent(relativePath)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let target = url(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: target)
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    private func validated(_ edits: [EditPlan.Edit]) throws -> ValidatedPlan {
        try EditPlanValidator.validate(EditPlan(edits: edits), in: vault())
    }

    // MARK: - Applying

    func testAppliesAllThreeOperations() throws {
        try write("# Index\n## Open\n", to: "notes/i.md")
        try write("# Day\n", to: "daily/d.md")

        let applied = try EditPlanApplier.apply(validated([
            .create(path: "notes/new.md", content: "# New\n"),
            .append(path: "daily/d.md", text: "- entry\n"),
            .replace(path: "notes/i.md", find: "## Open\n", with: "## Open\n- new\n"),
        ]))

        XCTAssertEqual(try read("notes/new.md"), "# New\n")
        XCTAssertEqual(try read("daily/d.md"), "# Day\n- entry\n")
        XCTAssertEqual(try read("notes/i.md"), "# Index\n## Open\n- new\n")
        XCTAssertEqual(applied.filesChanged.count, 3)
    }

    func testCreatesIntermediateFolders() throws {
        let applied = try EditPlanApplier.apply(validated([
            .create(path: "projects/2026/kickoff.md", content: "# Kickoff\n"),
        ]))
        XCTAssertEqual(try read("projects/2026/kickoff.md"), "# Kickoff\n")
        XCTAssertEqual(applied.undo.createdDirectories.count, 2)
    }

    /// A file touched twice appears once in filesChanged, in first-touched
    /// order, because that list is what the peek reports.
    func testFilesChangedIsDistinctAndOrdered() throws {
        try write("# A\n", to: "notes/a.md")
        let applied = try EditPlanApplier.apply(validated([
            .append(path: "notes/a.md", text: "- one\n"),
            .create(path: "notes/b.md", content: "# B\n"),
            .append(path: "notes/a.md", text: "- two\n"),
        ]))
        XCTAssertEqual(applied.filesChanged.map(\.lastPathComponent), ["a.md", "b.md"])
        XCTAssertEqual(try read("notes/a.md"), "# A\n- one\n- two\n")
    }

    // MARK: - Undo record

    /// Undo returns to the start of the run, not to a midpoint, so the
    /// pre-image is the state before the *first* edit to a file.
    func testUndoRecordKeepsTheOriginalPreImageForFilesTouchedTwice() throws {
        try write("# A\n", to: "notes/a.md")
        let applied = try EditPlanApplier.apply(validated([
            .append(path: "notes/a.md", text: "- one\n"),
            .append(path: "notes/a.md", text: "- two\n"),
        ]))
        XCTAssertEqual(applied.undo.entries.count, 1)
        XCTAssertEqual(applied.undo.entries[0].before, "# A\n")
    }

    func testUndoRecordMarksCreatedFilesAsAbsentBefore() throws {
        let applied = try EditPlanApplier.apply(validated([
            .create(path: "notes/new.md", content: "# New\n"),
        ]))
        XCTAssertEqual(applied.undo.entries.count, 1)
        XCTAssertNil(applied.undo.entries[0].before)
    }

    // MARK: - Concurrent external writers (§1)

    func testRefusesWhenFileChangedBetweenCheckAndApply() throws {
        try write("# A\n", to: "notes/a.md")
        let plan = try validated([.append(path: "notes/a.md", text: "- x\n")])

        // register's UI / a sync client writes the same file.
        try write("# A (edited elsewhere)\n", to: "notes/a.md")

        XCTAssertThrowsError(try EditPlanApplier.apply(plan)) { error in
            XCTAssertEqual(
                error as? EditPlanApplyError, .changedUnderfoot(path: "notes/a.md")
            )
        }
        XCTAssertEqual(try read("notes/a.md"), "# A (edited elsewhere)\n", "must not clobber")
    }

    func testRefusesWhenCreateTargetAppearsBetweenCheckAndApply() throws {
        let plan = try validated([.create(path: "notes/new.md", content: "# Mine\n")])
        try write("# Theirs\n", to: "notes/new.md")

        XCTAssertThrowsError(try EditPlanApplier.apply(plan)) { error in
            XCTAssertEqual(
                error as? EditPlanApplyError, .changedUnderfoot(path: "notes/new.md")
            )
        }
        XCTAssertEqual(try read("notes/new.md"), "# Theirs\n", "the other writer's content wins")
    }

    func testRefusesWhenFileVanishesBetweenCheckAndApply() throws {
        try write("# A\n", to: "notes/a.md")
        let plan = try validated([.append(path: "notes/a.md", text: "- x\n")])
        try FileManager.default.removeItem(at: url("notes/a.md"))

        XCTAssertThrowsError(try EditPlanApplier.apply(plan)) { error in
            XCTAssertEqual(error as? EditPlanApplyError, .changedUnderfoot(path: "notes/a.md"))
        }
    }

    // MARK: - All or nothing

    func testFailureRollsBackEarlierSteps() throws {
        try write("# A\n", to: "notes/a.md")
        try write("# B\n", to: "notes/b.md")
        let plan = try validated([
            .append(path: "notes/a.md", text: "- one\n"),
            .append(path: "notes/b.md", text: "- two\n"),
        ])

        // Make the second step fail after the first has already landed.
        try write("# B (edited elsewhere)\n", to: "notes/b.md")

        XCTAssertThrowsError(try EditPlanApplier.apply(plan))
        XCTAssertEqual(try read("notes/a.md"), "# A\n", "the first step must be rolled back")
        XCTAssertEqual(try read("notes/b.md"), "# B (edited elsewhere)\n")
    }

    func testRollbackRemovesFilesTheFailedPlanCreated() throws {
        try write("# B\n", to: "notes/b.md")
        let plan = try validated([
            .create(path: "notes/created.md", content: "# C\n"),
            .append(path: "notes/b.md", text: "- two\n"),
        ])
        try write("# B (edited elsewhere)\n", to: "notes/b.md")

        XCTAssertThrowsError(try EditPlanApplier.apply(plan))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url("notes/created.md").path),
            "a file created by a failed plan must not survive it"
        )
    }

    // MARK: - Empty plan

    func testEmptyPlanChangesNothing() throws {
        let applied = try EditPlanApplier.apply(validated([]))
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(applied.undo.isEmpty)
    }
}
