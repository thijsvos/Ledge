import LedgeCore
import XCTest

/// SlashSuggestionModel: query tokenization, wrap-around selection, the
/// Enter complete-vs-raw-submit policy (what string reaches the coordinator),
/// completion semantics, and the visible-row budget. The model is @MainActor
/// (it backs the capture field), so the whole case runs on the main actor.
///
/// The source is the STATIC native-command list (`NativeCommand`, declaration
/// order: help, settings, checks, vault, resume, cancel, quit) — the Claude
/// catalog no longer feeds the UI, so there is no catalog to inject and the
/// old catalog-swap clamp scenario (matches shrinking without a text edit)
/// can no longer occur: any text edit resets the selection.
@MainActor
final class SlashSuggestionModelTests: XCTestCase {
    // MARK: - Query tokenization

    func testQueryIsNilWithoutSlashPrefix() {
        let model = SlashSuggestionModel()
        for text in ["", "hello", " /help", ".i note"] {
            model.text = text
            XCTAssertNil(model.query, text)
            XCTAssertEqual(model.matches, [], text)
            XCTAssertFalse(model.isListVisible, text)
        }
    }

    func testBareSlashQueriesEmptyPrefixAndListsAllNativeCommands() {
        let model = SlashSuggestionModel()
        model.text = "/"
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.matches, NativeCommand.allCases)
        XCTAssertTrue(model.isListVisible)
    }

    func testQueryIsTokenBetweenSlashAndFirstSpace() {
        let model = SlashSuggestionModel()
        model.text = "/c"
        XCTAssertEqual(model.query, "c")
        // Declaration order, not alphabetical: checks before cancel.
        XCTAssertEqual(model.matches, [.checks, .cancel])
    }

    func testSpaceAfterTokenHidesTheList() {
        let model = SlashSuggestionModel()
        model.text = "/cancel now"
        XCTAssertNil(model.query)
        XCTAssertFalse(model.isListVisible)
        // The completion text itself ("/cancel ") also hides the list.
        model.text = "/cancel "
        XCTAssertFalse(model.isListVisible)
    }

    // MARK: - Selection

    func testMoveSelectionWrapsAtBothEnds() {
        let model = SlashSuggestionModel()
        model.text = "/"
        let last = NativeCommand.allCases.count - 1
        XCTAssertEqual(model.highlightIndex, 0)
        model.moveSelection(by: -1) // ↑ from the first row → last
        XCTAssertEqual(model.highlightIndex, last)
        XCTAssertEqual(model.selectedCommand, .quit)
        model.moveSelection(by: 1) // ↓ from the last row → first
        XCTAssertEqual(model.highlightIndex, 0)
        XCTAssertEqual(model.selectedCommand, .help)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedCommand, .checks)
    }

    func testEditingTextResetsSelectionAndMovedFlag() {
        let model = SlashSuggestionModel()
        model.text = "/"
        model.moveSelection(by: 1)
        XCTAssertTrue(model.hasUserMovedSelection)
        model.text = "/c"
        XCTAssertFalse(model.hasUserMovedSelection)
        XCTAssertEqual(model.highlightIndex, 0)
    }

    func testMoveSelectionWithNoMatchesIsANoOp() {
        let model = SlashSuggestionModel()
        model.text = "/zzz"
        model.moveSelection(by: 1)
        XCTAssertFalse(model.isListVisible)
        XCTAssertNil(model.selectedCommand)
        XCTAssertFalse(model.shouldCompleteOnReturn)
    }

    // MARK: - Enter policy (what Enter submits)

    func testBareSlashEnterNeverAutoCompletes() {
        // "/" matches the whole list (empty query): Enter must fall through
        // and submit the raw "/" — never silently run a command.
        let model = SlashSuggestionModel()
        model.text = "/"
        XCTAssertTrue(model.isListVisible)
        XCTAssertFalse(model.shouldCompleteOnReturn)
    }

    func testAmbiguousQueryDoesNotAutoCompleteOnEnter() {
        let model = SlashSuggestionModel()
        model.text = "/c" // checks + cancel
        XCTAssertEqual(model.matches.count, 2)
        XCTAssertFalse(model.shouldCompleteOnReturn)
    }

    func testSingleUnambiguousMatchWithARealQueryCompletesOnEnter() {
        // New with the native list: "/ca" + Enter runs /cancel — a real
        // (non-empty) token with exactly one match is unambiguous, and the
        // list renders that lone row highlighted under the same condition.
        let model = SlashSuggestionModel()
        model.text = "/ca"
        XCTAssertEqual(model.matches, [.cancel])
        XCTAssertTrue(model.shouldCompleteOnReturn)
        XCTAssertEqual(model.selectedCommand, .cancel)
        XCTAssertFalse(model.hasUserMovedSelection)
    }

    func testEnterCompletesAfterTheUserMovedTheSelection() {
        let model = SlashSuggestionModel()
        model.text = "/c"
        XCTAssertFalse(model.shouldCompleteOnReturn)
        model.moveSelection(by: 1)
        XCTAssertTrue(model.shouldCompleteOnReturn)
        XCTAssertEqual(model.selectedCommand, .cancel)
        XCTAssertTrue(model.hasUserMovedSelection)
    }

    // MARK: - submitActionOnReturn (what the target chip must show)

    func testSubmitActionOnReturnMatchesWhatEnterActuallyDoes() {
        // The chip renders from this seam; a divergence from the key
        // monitor's Enter behavior would make the chip lie exactly when
        // Enter is destructive ("/q" quits while decide() says agent).
        let model = SlashSuggestionModel()
        model.text = "/q" // single match → Enter auto-runs /quit
        XCTAssertTrue(model.shouldCompleteOnReturn)
        XCTAssertEqual(model.submitActionOnReturn, .native(.quit))
        model.text = "/ca" // single match → /cancel
        XCTAssertEqual(model.submitActionOnReturn, .native(.cancel))
        model.text = "/c" // ambiguous → raw submit → agent
        XCTAssertFalse(model.shouldCompleteOnReturn)
        XCTAssertEqual(model.submitActionOnReturn, .routed(.agent(prompt: "c")))
        model.moveSelection(by: 1) // explicit selection → that row runs
        XCTAssertEqual(model.submitActionOnReturn, .native(.cancel))
        model.text = "/cancel" // exact name: native with or without the list
        XCTAssertEqual(model.submitActionOnReturn, .native(.cancel))
        model.text = "/" // bare slash never auto-runs → raw agent submit
        XCTAssertEqual(model.submitActionOnReturn, .routed(.agent(prompt: "")))
        model.text = "/cancel now" // arguments → agent, list hidden
        XCTAssertEqual(model.submitActionOnReturn, .routed(.agent(prompt: "cancel now")))
        model.text = "hello" // no slash → instant capture routes untouched
        XCTAssertEqual(
            model.submitActionOnReturn,
            .routed(.instant(target: .daily, text: "hello"))
        )
        model.text = ".i note"
        XCTAssertEqual(
            model.submitActionOnReturn,
            .routed(.instant(target: .inbox, text: "note"))
        )
    }

    func testChooserGateNeverAgentRoutesAHighlightedNativeSuggestion() {
        // The ⌘↩ per-run model chooser activates only when
        // `submitActionOnReturn` is agent-routed (the window controller
        // gates on this seam, NOT on bare `SubmitAction.decide`): wherever
        // the two diverge, Enter runs a native command — the chip shows
        // "ledge", the row is highlighted — and offering a model there would
        // launch an agent run the UI never advertised.
        let model = SlashSuggestionModel()
        model.text = "/q" // single match → Enter auto-runs /quit
        XCTAssertEqual(SubmitAction.decide(model.text), .routed(.agent(prompt: "q")))
        XCTAssertEqual(model.submitActionOnReturn, .native(.quit)) // gate: no chooser
        model.text = "/c" // ambiguous, then an explicit ↓ highlights /cancel
        model.moveSelection(by: 1)
        XCTAssertEqual(SubmitAction.decide(model.text), .routed(.agent(prompt: "c")))
        XCTAssertEqual(model.submitActionOnReturn, .native(.cancel)) // gate: no chooser
        model.text = "/q " // token ended (shadow escape): agent again — chooser eligible
        XCTAssertEqual(model.submitActionOnReturn, .routed(.agent(prompt: "q ")))
    }

    // MARK: - Completion

    func testCompletionTextIsSlashNameSpace() {
        let model = SlashSuggestionModel()
        XCTAssertEqual(model.completionText(for: .vault), "/vault ")
        // The trailing space still executes natively on submit (match trims).
        XCTAssertEqual(NativeCommand.match(input: model.completionText(for: .vault)), .vault)
    }

    func testCompleteSelectionReplacesTextAndResetsSelectionState() {
        let model = SlashSuggestionModel()
        model.text = "/c"
        model.moveSelection(by: 1)
        model.completeSelection()
        XCTAssertEqual(model.text, "/cancel ")
        // The trailing space ends the query: list hidden, flag reset — a
        // following Enter submits the completed text through the TextField.
        XCTAssertFalse(model.isListVisible)
        XCTAssertFalse(model.hasUserMovedSelection)
        XCTAssertFalse(model.shouldCompleteOnReturn)
    }

    func testCompleteSelectionWithoutMatchesIsANoOp() {
        let model = SlashSuggestionModel()
        model.text = "/zzz"
        model.completeSelection()
        XCTAssertEqual(model.text, "/zzz")
    }

    // MARK: - Visible-row budget

    func testVisibleRowCountIsCappedAtFourRows() {
        // 4 is a hard content budget: the open overlay's chrome + rows must
        // fit the constant 200 pt window (5 fixed-height rows cannot). The
        // native list (7) therefore scrolls within 4 rows on the bare "/".
        XCTAssertEqual(SlashSuggestionModel.maxVisibleRows, 4)
        let model = SlashSuggestionModel()
        model.text = "/"
        XCTAssertEqual(model.matches.count, NativeCommand.allCases.count)
        XCTAssertEqual(model.visibleRowCount, 4)
        model.text = "/ca"
        XCTAssertEqual(model.visibleRowCount, 1)
    }
}
