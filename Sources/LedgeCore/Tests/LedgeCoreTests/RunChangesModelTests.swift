@testable import LedgeCore
import XCTest

/// The /changes pane's state. Same contract as ResumePickerModel — activate,
/// deactivate, wrapping selection, and a visible-row count the drawn shape and
/// the click hit-test both depend on.
@MainActor
final class RunChangesModelTests: XCTestCase {
    private func receipt(files: Int = 1, linesEach: Int = 1) -> RunReceipt {
        var edits: [EditPlan.Edit] = []
        var undo = RunUndoRecord()
        var urls: [URL] = []
        for file in 0 ..< files {
            let path = "notes/\(file).md"
            let url = URL(fileURLWithPath: "/vault/\(path)")
            urls.append(url)
            undo.record(url: url, before: "old")
            let body = (0 ..< linesEach).map { "line \($0)" }.joined(separator: "\n")
            edits.append(.append(path: path, text: body))
        }
        return RunReceipt(applied: AppliedPlan(
            filesChanged: urls,
            changes: edits.map {
                AppliedPlan.Change(url: URL(fileURLWithPath: "/vault/\($0.path)"), edit: $0)
            },
            undo: undo
        ))
    }

    // MARK: - Lifecycle

    func testStartsInactive() {
        let model = RunChangesModel()
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testActivateLoadsRows() {
        let model = RunChangesModel()
        model.activate(receipt: receipt(files: 2))
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.rows.count, 4, "two headings, one line each")
    }

    func testDeactivateDropsEverything() {
        let model = RunChangesModel()
        model.activate(receipt: receipt())
        model.moveSelection(by: 1)
        model.deactivate()
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    /// `/changes` after a run that changed nothing must say so, not silently
    /// do nothing — so an empty receipt still activates.
    func testNilOrEmptyReceiptStillActivates() {
        for value in [nil, RunReceipt(applied: AppliedPlan(
            filesChanged: [], changes: [], undo: RunUndoRecord()
        ))] {
            let model = RunChangesModel()
            model.activate(receipt: value)
            XCTAssertTrue(model.isActive)
            XCTAssertTrue(model.isEmpty)
            XCTAssertFalse(model.emptyMessage.isEmpty)
        }
    }

    func testActivateResetsSelectionFromAPreviousRun() {
        let model = RunChangesModel()
        model.activate(receipt: receipt(files: 3))
        model.moveSelection(by: 2)
        model.activate(receipt: receipt(files: 3))
        XCTAssertEqual(model.selectedIndex, 0)
    }

    // MARK: - Selection

    func testSelectionWrapsBothWays() {
        let model = RunChangesModel()
        model.activate(receipt: receipt(files: 2)) // 4 rows
        model.moveSelection(by: -1)
        XCTAssertEqual(model.highlightIndex, 3, "up from the top wraps to the end")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.highlightIndex, 0, "down from the end wraps to the top")
    }

    func testSelectionOnAnEmptyPaneIsInert() {
        let model = RunChangesModel()
        model.activate(receipt: nil)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.highlightIndex, 0)
    }

    // MARK: - The number the drawn shape and the hit-test share

    func testVisibleRowCountIsAtLeastOneAndNeverExceedsTheCap() {
        let model = RunChangesModel()
        model.activate(receipt: nil)
        XCTAssertEqual(model.visibleRowCount, 1, "the empty message still needs a row")

        model.activate(receipt: receipt(files: 20))
        XCTAssertEqual(model.visibleRowCount, RunChangesModel.maxVisibleRows)
        XCTAssertLessThanOrEqual(
            model.visibleRowCount, RunChangesModel.maxVisibleRows,
            "exceeding this makes the drawn shape and the click hit-test disagree"
        )
    }

    func testVisibleRowCountTracksSmallReceipts() {
        let model = RunChangesModel()
        model.activate(receipt: receipt(files: 1)) // heading + 1 line
        XCTAssertEqual(model.visibleRowCount, 2)
    }
}
