import LedgeCore
import XCTest

/// ResumePickerModel: activation validity-filtering (only records whose
/// session ID passes the exact ResumeScriptWriter guard are offered), the
/// case-insensitive substring filter, wrap-around selection, the visible-row
/// cap (5), and full state reset on deactivation. @MainActor like the model
/// itself (it backs the capture field while the picker is up).
@MainActor
final class ResumePickerModelTests: XCTestCase {
    private func makeRecord(
        prompt: String,
        sessionID: String?,
        vaultPath: String = "/tmp/vault"
    ) -> RunRecord {
        RunRecord(
            id: UUID(),
            date: Date(timeIntervalSinceReferenceDate: 777_000_000),
            vaultPath: vaultPath,
            prompt: prompt,
            sessionID: sessionID,
            outcome: .success,
            editedFiles: [],
            durationMS: nil,
            resultExcerpt: nil,
            stderrTail: []
        )
    }

    // MARK: - Validity filter

    func testResumableRecordsKeepsOnlyValidSessionIDs() {
        let valid1 = makeRecord(prompt: "one", sessionID: "abc-123-DEF")
        let noID = makeRecord(prompt: "two", sessionID: nil)
        let empty = makeRecord(prompt: "three", sessionID: "")
        let injection = makeRecord(prompt: "four", sessionID: "id'; rm -rf ~")
        let unicode = makeRecord(prompt: "five", sessionID: "sess💥")
        let valid2 = makeRecord(prompt: "six", sessionID: "0f9e8d7c")

        XCTAssertEqual(
            ResumePickerModel.resumableRecords([valid1, noID, empty, injection, unicode, valid2]),
            [valid1, valid2]
        )
    }

    func testActivateAppliesTheValidityFilter() {
        let model = ResumePickerModel()
        let valid = makeRecord(prompt: "keep", sessionID: "sess-1")
        model.activate(records: [valid, makeRecord(prompt: "drop", sessionID: nil)])
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.records, [valid])
    }

    // MARK: - Text filter

    func testFilterIsCaseInsensitiveSubstringOverPrompt() {
        let model = ResumePickerModel()
        let summarize = makeRecord(prompt: "Summarize the Inbox", sessionID: "a-1")
        let vet = makeRecord(prompt: "vet the diff", sessionID: "a-2")
        let unicode = makeRecord(prompt: "Café notes 整理", sessionID: "a-3")
        model.activate(records: [summarize, vet, unicode])

        XCTAssertEqual(model.filteredRecords, [summarize, vet, unicode]) // empty filter: all
        model.filterText = "INBOX"
        XCTAssertEqual(model.filteredRecords, [summarize])
        model.filterText = "the"
        XCTAssertEqual(model.filteredRecords, [summarize, vet]) // order preserved
        model.filterText = "café"
        XCTAssertEqual(model.filteredRecords, [unicode])
        model.filterText = "no such prompt"
        XCTAssertEqual(model.filteredRecords, [])
        XCTAssertNil(model.selectedRecord)
    }

    func testEditingFilterResetsSelection() {
        let model = ResumePickerModel()
        model.activate(records: (1 ... 4).map { makeRecord(prompt: "run \($0)", sessionID: "s-\($0)") })
        model.moveSelection(by: 2)
        XCTAssertEqual(model.highlightIndex, 2)
        model.filterText = "run"
        XCTAssertEqual(model.highlightIndex, 0)
    }

    // MARK: - Selection

    func testSelectionWrapsAtBothEnds() {
        let model = ResumePickerModel()
        model.activate(records: (1 ... 3).map { makeRecord(prompt: "run \($0)", sessionID: "s-\($0)") })
        XCTAssertEqual(model.highlightIndex, 0)
        XCTAssertEqual(model.selectedRecord?.prompt, "run 1") // default: newest row
        model.moveSelection(by: -1) // ↑ from first → last
        XCTAssertEqual(model.selectedRecord?.prompt, "run 3")
        model.moveSelection(by: 1) // ↓ from last → first
        XCTAssertEqual(model.selectedRecord?.prompt, "run 1")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedRecord?.prompt, "run 2")
    }

    func testSelectionClampsWhenFilterShrinksTheList() {
        let model = ResumePickerModel()
        let rows = [
            makeRecord(prompt: "alpha", sessionID: "s-1"),
            makeRecord(prompt: "beta", sessionID: "s-2"),
            makeRecord(prompt: "alpha beta", sessionID: "s-3"),
        ]
        model.activate(records: rows)
        model.moveSelection(by: 2) // third row
        model.filterText = "beta" // two rows remain; selection reset to top
        XCTAssertEqual(model.highlightIndex, 0)
        XCTAssertEqual(model.selectedRecord?.prompt, "beta")
    }

    // MARK: - Row budget

    func testVisibleRowCountCapsAtFive() {
        let model = ResumePickerModel()
        model.activate(records: (1 ... 8).map { makeRecord(prompt: "run \($0)", sessionID: "s-\($0)") })
        XCTAssertEqual(model.visibleRowCount, ResumePickerModel.maxVisibleRows)
        XCTAssertEqual(ResumePickerModel.maxVisibleRows, 5)
        model.filterText = "run 3"
        XCTAssertEqual(model.visibleRowCount, 1)
    }

    // MARK: - Seeded fallback flag

    /// The stored-lastSessionID fallback row carries fabricated date/outcome
    /// placeholders — the flag is what tells the UI to render it neutrally
    /// (no time, no glyph), and it must never leak into a later activation.
    func testSeededFallbackFlagFollowsActivation() {
        let model = ResumePickerModel()
        XCTAssertFalse(model.isSeededFallback)

        model.activate(
            records: [makeRecord(prompt: "last session", sessionID: "s-1")],
            seededLastSession: true
        )
        XCTAssertTrue(model.isSeededFallback)

        model.deactivate()
        XCTAssertFalse(model.isSeededFallback)

        model.activate(records: [makeRecord(prompt: "recorded", sessionID: "s-2")])
        XCTAssertFalse(model.isSeededFallback, "default activation is real history")
    }

    // MARK: - Lifecycle

    func testDeactivateResetsAllState() {
        let model = ResumePickerModel()
        model.activate(
            records: [makeRecord(prompt: "run", sessionID: "s-1")],
            seededLastSession: true
        )
        model.filterText = "ru"
        model.moveSelection(by: 1)
        model.deactivate()
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.isSeededFallback)
        XCTAssertEqual(model.records, [])
        XCTAssertEqual(model.filterText, "")
        XCTAssertEqual(model.highlightIndex, 0)
        XCTAssertNil(model.selectedRecord)
    }

    func testActivateResetsFilterAndSelectionFromAPreviousActivation() {
        let model = ResumePickerModel()
        model.activate(records: (1 ... 3).map { makeRecord(prompt: "old \($0)", sessionID: "s-\($0)") })
        model.filterText = "old"
        model.moveSelection(by: 1)
        let fresh = makeRecord(prompt: "fresh", sessionID: "s-9")
        model.activate(records: [fresh])
        XCTAssertEqual(model.filterText, "")
        XCTAssertEqual(model.highlightIndex, 0)
        XCTAssertEqual(model.selectedRecord, fresh)
    }
}
