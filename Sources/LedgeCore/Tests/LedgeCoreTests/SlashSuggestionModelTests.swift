import LedgeCore
import XCTest

/// SlashSuggestionModel: query tokenization, wrap-around selection, the
/// Enter complete-vs-raw-submit policy (what string reaches the coordinator),
/// completion semantics, and the visible-row budget. The model is @MainActor
/// (it backs the capture field), so the whole case runs on the main actor.
@MainActor
final class SlashSuggestionModelTests: XCTestCase {
    private func makeModel(names: [String] = ["alpha", "beta", "beta-two"]) -> SlashSuggestionModel {
        let model = SlashSuggestionModel()
        model.catalog = SlashCommandCatalog(
            commands: names.map { SlashCommand(name: $0, source: .userCommand) }
        )
        return model
    }

    // MARK: - Query tokenization

    func testQueryIsNilWithoutSlashPrefix() {
        let model = makeModel()
        for text in ["", "hello", " /alpha", ".i note"] {
            model.text = text
            XCTAssertNil(model.query, text)
            XCTAssertEqual(model.matches, [], text)
            XCTAssertFalse(model.isListVisible, text)
        }
    }

    func testBareSlashQueriesEmptyPrefixAndMatchesAll() {
        let model = makeModel()
        model.text = "/"
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.matches.map(\.name), ["alpha", "beta", "beta-two"])
        XCTAssertTrue(model.isListVisible)
    }

    func testQueryIsTokenBetweenSlashAndFirstSpace() {
        let model = makeModel()
        model.text = "/be"
        XCTAssertEqual(model.query, "be")
        XCTAssertEqual(model.matches.map(\.name), ["beta", "beta-two"])
    }

    func testSpaceAfterTokenHidesTheList() {
        let model = makeModel()
        model.text = "/beta args"
        XCTAssertNil(model.query)
        XCTAssertFalse(model.isListVisible)
        // The completion text itself ("/beta ") also hides the list.
        model.text = "/beta "
        XCTAssertFalse(model.isListVisible)
    }

    // MARK: - Selection

    func testMoveSelectionWrapsAtBothEnds() {
        let model = makeModel()
        model.text = "/"
        XCTAssertEqual(model.highlightIndex, 0)
        model.moveSelection(by: -1) // ↑ from the first row → last
        XCTAssertEqual(model.highlightIndex, 2)
        model.moveSelection(by: 1) // ↓ from the last row → first
        XCTAssertEqual(model.highlightIndex, 0)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.highlightIndex, 2)
        XCTAssertEqual(model.selectedCommand?.name, "beta-two")
    }

    func testEditingTextResetsSelectionAndMovedFlag() {
        let model = makeModel()
        model.text = "/"
        model.moveSelection(by: 1)
        XCTAssertTrue(model.hasUserMovedSelection)
        model.text = "/b"
        XCTAssertFalse(model.hasUserMovedSelection)
        XCTAssertEqual(model.highlightIndex, 0)
    }

    func testHighlightClampsWhenMatchesShrinkUnderTheSelection() {
        let model = makeModel()
        model.text = "/"
        model.moveSelection(by: -1) // index 2
        // A fresh scan can land a smaller catalog without a text edit.
        model.catalog = SlashCommandCatalog(
            commands: [SlashCommand(name: "only", source: .userCommand)]
        )
        XCTAssertEqual(model.highlightIndex, 0)
        XCTAssertEqual(model.selectedCommand?.name, "only")
    }

    func testMoveSelectionWithNoMatchesIsANoOp() {
        let model = makeModel()
        model.text = "/zzz"
        model.moveSelection(by: 1)
        XCTAssertFalse(model.isListVisible)
        XCTAssertNil(model.selectedCommand)
        XCTAssertFalse(model.shouldCompleteOnReturn)
    }

    // MARK: - Enter policy (what Enter submits)

    func testEnterNeverAutoCompletesWithoutAnActiveSelection() {
        // Regression: with a single installed command, "/" + Enter (or a
        // partial "/al" + Enter) must NOT complete-and-submit a command the
        // user never typed — Enter falls through and submits the raw text.
        let model = makeModel(names: ["alpha"])
        model.text = "/"
        XCTAssertTrue(model.isListVisible)
        XCTAssertFalse(model.shouldCompleteOnReturn)
        model.text = "/al"
        XCTAssertEqual(model.matches.count, 1)
        XCTAssertFalse(model.shouldCompleteOnReturn)
    }

    func testEnterCompletesOnlyAfterTheUserMovedTheSelection() {
        let model = makeModel()
        model.text = "/be"
        XCTAssertFalse(model.shouldCompleteOnReturn)
        model.moveSelection(by: 1)
        XCTAssertTrue(model.shouldCompleteOnReturn)
        XCTAssertEqual(model.selectedCommand?.name, "beta-two")
        // The highlight-visible condition and the Enter condition are the
        // same flag — what the user sees highlighted is what Enter runs.
        XCTAssertTrue(model.hasUserMovedSelection)
    }

    // MARK: - Completion

    func testCompletionTextIsSlashNameSpace() {
        let model = makeModel()
        let command = SlashCommand(name: "foo:bar", source: .projectCommand)
        XCTAssertEqual(model.completionText(for: command), "/foo:bar ")
    }

    func testCompleteSelectionReplacesTextAndResetsSelectionState() {
        let model = makeModel()
        model.text = "/be"
        model.moveSelection(by: 1)
        model.completeSelection()
        XCTAssertEqual(model.text, "/beta-two ")
        // The trailing space ends the query: list hidden, flag reset — a
        // following Enter submits the completed text through the TextField.
        XCTAssertFalse(model.isListVisible)
        XCTAssertFalse(model.hasUserMovedSelection)
        XCTAssertFalse(model.shouldCompleteOnReturn)
    }

    func testCompleteSelectionWithoutMatchesIsANoOp() {
        let model = makeModel()
        model.text = "/zzz"
        model.completeSelection()
        XCTAssertEqual(model.text, "/zzz")
    }

    // MARK: - Visible-row budget

    func testVisibleRowCountIsCappedAtFourRows() {
        // 4 is a hard content budget: the open overlay's chrome + rows must
        // fit the constant 200 pt window (5 fixed-height rows cannot).
        XCTAssertEqual(SlashSuggestionModel.maxVisibleRows, 4)
        let model = makeModel(names: ["a", "b", "c", "d", "e", "f"])
        model.text = "/"
        XCTAssertEqual(model.matches.count, 6)
        XCTAssertEqual(model.visibleRowCount, 4)
        model.text = "/a"
        XCTAssertEqual(model.visibleRowCount, 1)
    }
}
