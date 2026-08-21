@testable import LedgeCore
import XCTest

/// What a run did, rendered for the notch (§2.3).
///
/// The receipt exists because "✓ 2 files" drops the paths, leaving `git diff`
/// in a terminal as the only way to see an agent's edits — and a vault need not
/// be a git repo. These pin that it renders from the edits alone: no diffing,
/// no file content, and never an absolute path.
final class RunReceiptTests: XCTestCase {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: "/vault/\(path)")
    }

    /// Mirrors what the applier hands back: the edits it applied, plus an undo
    /// record whose nil pre-images mark the files the run created.
    private func applied(
        _ edits: [EditPlan.Edit],
        created: [String] = []
    ) -> AppliedPlan {
        var undo = RunUndoRecord()
        var seen: [URL] = []
        for edit in edits where !seen.contains(url(edit.path)) {
            seen.append(url(edit.path))
            undo.record(
                url: url(edit.path),
                before: created.contains(edit.path) ? nil : "old contents"
            )
        }
        return AppliedPlan(
            filesChanged: seen,
            changes: edits.map { AppliedPlan.Change(url: url($0.path), edit: $0) },
            undo: undo
        )
    }

    private func texts(_ rows: [RunReceipt.Row]) -> [String] {
        rows.map(\.text)
    }

    // MARK: - The three operations render from the edit alone

    func testAppendShowsTheAppendedLine() {
        let receipt = RunReceipt(applied: applied([
            .append(path: "daily/2026-08-21.md", text: "- 14:03Z Met Sam\n"),
        ]))
        XCTAssertEqual(texts(receipt.rows()), [
            "daily/2026-08-21.md",
            "- 14:03Z Met Sam",
        ])
        XCTAssertEqual(receipt.rows()[1].kind, .added)
    }

    func testCreateShowsTheNewContentAndMarksTheFileNew() {
        let receipt = RunReceipt(applied: applied(
            [.create(path: "notes/021-sam.md", content: "# Sam sync\n")],
            created: ["notes/021-sam.md"]
        ))
        XCTAssertEqual(receipt.rows().first?.kind, .file(isNew: true))
        XCTAssertEqual(texts(receipt.rows()), ["notes/021-sam.md", "# Sam sync"])
    }

    /// `replace` is the only op that removes text, so it is the only one that
    /// produces a removed row — and it must show both halves.
    func testReplaceShowsRemovedThenAdded() {
        let receipt = RunReceipt(applied: applied([
            .replace(path: "notes/index.md", find: "## Open", with: "## Open\n- Sam sync"),
        ]))
        let rows = receipt.rows()
        XCTAssertEqual(texts(rows), ["notes/index.md", "## Open", "## Open", "- Sam sync"])
        XCTAssertEqual(rows[1].kind, .removed)
        XCTAssertEqual(rows[2].kind, .added)
        XCTAssertEqual(rows[3].kind, .added)
    }

    func testEditedFileIsNotMarkedNew() {
        let receipt = RunReceipt(applied: applied([
            .append(path: "daily/2026-08-21.md", text: "- a line\n"),
        ]))
        XCTAssertEqual(receipt.rows().first?.kind, .file(isNew: false))
    }

    // MARK: - Grouping

    func testSeveralEditsToOneFileShareOneHeading() {
        let receipt = RunReceipt(applied: applied([
            .append(path: "daily/d.md", text: "- first\n"),
            .append(path: "daily/d.md", text: "- second\n"),
        ]))
        XCTAssertEqual(receipt.files.count, 1)
        XCTAssertEqual(receipt.files[0].edits.count, 2)
        XCTAssertEqual(texts(receipt.rows()), ["daily/d.md", "- first", "- second"])
    }

    func testFilesKeepFirstTouchedOrder() {
        let receipt = RunReceipt(applied: applied([
            .append(path: "b.md", text: "x\n"),
            .append(path: "a.md", text: "y\n"),
            .append(path: "b.md", text: "z\n"),
        ]))
        XCTAssertEqual(receipt.files.map(\.path), ["b.md", "a.md"])
    }

    // MARK: - Fitting a 200 pt window

    /// One runaway `create` must not push every other file off the pane.
    func testLongChangeIsElidedWithACount() {
        let body = (1 ... 20).map { "line \($0)" }.joined(separator: "\n")
        let receipt = RunReceipt(applied: applied(
            [.create(path: "notes/long.md", content: body)],
            created: ["notes/long.md"]
        ))
        let rows = receipt.rows(maxLinesPerFile: 6)
        XCTAssertEqual(rows.count, 7, "1 heading + 5 lines + 1 elision")
        XCTAssertEqual(rows.last?.kind, .elision)
        XCTAssertEqual(rows.last?.text, "+15 more")
    }

    func testAShortChangeIsNotElided() {
        let receipt = RunReceipt(applied: applied([
            .append(path: "a.md", text: "one\ntwo\n"),
        ]))
        XCTAssertFalse(receipt.rows().contains { $0.kind == .elision })
    }

    /// Blank lines cost a whole row at this size and say nothing.
    func testBlankLinesAreDropped() {
        let receipt = RunReceipt(applied: applied([
            .append(path: "a.md", text: "\n\nreal line\n\n"),
        ]))
        XCTAssertEqual(texts(receipt.rows()), ["a.md", "real line"])
    }

    // MARK: - The agent's own words

    func testExplanationLeadsWhenPresent() {
        let receipt = RunReceipt(
            applied: applied([.append(path: "a.md", text: "x\n")]),
            explanation: "Filed it under today's log."
        )
        XCTAssertEqual(receipt.rows().first?.kind, .explanation)
        XCTAssertEqual(receipt.rows().first?.text, "Filed it under today's log.")
    }

    func testBlankOrMissingExplanationAddsNoRow() {
        for explanation in [nil, "", "   \n  "] {
            let receipt = RunReceipt(
                applied: applied([.append(path: "a.md", text: "x\n")]),
                explanation: explanation
            )
            XCTAssertNil(receipt.explanation, "\(explanation ?? "nil")")
            XCTAssertEqual(receipt.rows().first?.kind, .file(isNew: false))
        }
    }

    // MARK: - Never leak an absolute path

    /// The edit's own path is vault-relative and is what the user asked about;
    /// the URL is absolute and would put a home folder on screen.
    func testPathsAreVaultRelative() {
        let receipt = RunReceipt(applied: applied([
            .append(path: "daily/2026-08-21.md", text: "x\n"),
        ]))
        XCTAssertEqual(receipt.files[0].path, "daily/2026-08-21.md")
        XCTAssertFalse(receipt.rows()[0].text.contains("/vault"))
    }

    // MARK: - Nothing to show

    func testEmptyPlanProducesAnEmptyReceipt() {
        let receipt = RunReceipt(applied: applied([]))
        XCTAssertTrue(receipt.isEmpty)
        XCTAssertTrue(receipt.rows().isEmpty)
    }
}
