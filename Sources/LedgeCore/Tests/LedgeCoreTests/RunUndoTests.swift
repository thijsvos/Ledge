@testable import LedgeCore
import XCTest

/// Taking a run back (§2.3). The QA criterion is that `git diff` in the vault
/// is clean after `/undo`, so these pin byte-for-byte restoration.
final class RunUndoTests: XCTestCase {
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

    private func applying(_ edits: [EditPlan.Edit]) throws -> AppliedPlan {
        try EditPlanApplier.apply(
            EditPlanValidator.validate(EditPlan(edits: edits), in: vault())
        )
    }

    // MARK: - Round trip through a real run

    func testUndoRestoresChangedFileByteForByte() throws {
        let original = "# Day\n- existing entry\n"
        try write(original, to: "daily/d.md")
        let applied = try applying([.append(path: "daily/d.md", text: "- agent entry\n")])
        XCTAssertNotEqual(try read("daily/d.md"), original)

        XCTAssertEqual(RunUndo.restore(applied.undo), 1)
        XCTAssertEqual(try read("daily/d.md"), original)
    }

    func testUndoRemovesFilesTheRunCreated() throws {
        let applied = try applying([.create(path: "notes/new.md", content: "# New\n")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("notes/new.md").path))

        XCTAssertEqual(RunUndo.restore(applied.undo), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("notes/new.md").path))
    }

    func testUndoRestoresAMixedPlanCompletely() throws {
        try write("# Index\n## Open\n", to: "notes/i.md")
        try write("# Day\n", to: "daily/d.md")
        let applied = try applying([
            .create(path: "notes/new.md", content: "# New\n"),
            .append(path: "daily/d.md", text: "- entry\n"),
            .replace(path: "notes/i.md", find: "## Open\n", with: "## Open\n- new\n"),
        ])

        XCTAssertEqual(RunUndo.restore(applied.undo), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("notes/new.md").path))
        XCTAssertEqual(try read("daily/d.md"), "# Day\n")
        XCTAssertEqual(try read("notes/i.md"), "# Index\n## Open\n")
    }

    /// A file edited twice in one run goes back to where it started, not to
    /// the midpoint between the two edits.
    func testUndoOfTwoEditsToOneFileReturnsToTheStartOfTheRun() throws {
        try write("# A\n", to: "notes/a.md")
        let applied = try applying([
            .append(path: "notes/a.md", text: "- one\n"),
            .append(path: "notes/a.md", text: "- two\n"),
        ])
        RunUndo.restore(applied.undo)
        XCTAssertEqual(try read("notes/a.md"), "# A\n")
    }

    // MARK: - Folders

    func testUndoRemovesFoldersTheRunCreated() throws {
        let applied = try applying([.create(path: "projects/2026/kickoff.md", content: "x")])
        RunUndo.restore(applied.undo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("projects/2026").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("projects").path))
    }

    /// A folder the user has since put something else into stays.
    func testUndoKeepsCreatedFolderThatIsNoLongerEmpty() throws {
        let applied = try applying([.create(path: "projects/kickoff.md", content: "x")])
        try write("# Mine\n", to: "projects/mine.md")

        RunUndo.restore(applied.undo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("projects").path))
        XCTAssertEqual(try read("projects/mine.md"), "# Mine\n")
    }

    // MARK: - Record bookkeeping

    func testRecordKeepsFirstTouchAndIgnoresLaterOnes() {
        var record = RunUndoRecord()
        record.record(url: url("a.md"), before: "first")
        record.record(url: url("a.md"), before: "second")
        XCTAssertEqual(record.entries.count, 1)
        XCTAssertEqual(record.entries[0].before, "first")
    }

    func testEmptyRecordRestoresNothing() {
        XCTAssertEqual(RunUndo.restore(RunUndoRecord()), 0)
        XCTAssertTrue(RunUndoRecord().isEmpty)
        XCTAssertEqual(RunUndoRecord().fileCount, 0)
    }

    /// Best-effort: a file the user already deleted must not strand the rest
    /// of the undo.
    func testUndoContinuesPastAFileItCannotRestore() throws {
        try write("# A\n", to: "notes/a.md")
        let applied = try applying([
            .create(path: "notes/created.md", content: "x"),
            .append(path: "notes/a.md", text: "- one\n"),
        ])
        // The user removes the created file themselves before hitting undo.
        try FileManager.default.removeItem(at: url("notes/created.md"))

        RunUndo.restore(applied.undo)
        XCTAssertEqual(try read("notes/a.md"), "# A\n", "the other file still comes back")
    }
}
