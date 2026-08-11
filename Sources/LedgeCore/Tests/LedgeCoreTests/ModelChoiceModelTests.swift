import LedgeCore
import XCTest

/// ModelChoiceModel (the ⌘↩ per-run model chooser): the fixed activation
/// rows and their subtitles, wrap-around selection, and full reset on
/// deactivation. @MainActor like the model itself (it backs the open
/// island's chooser list).
@MainActor
final class ModelChoiceModelTests: XCTestCase {
    func testActivationOffersExactlyTheThreeFixedRows() {
        let model = ModelChoiceModel()
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.rows.isEmpty)

        model.activate(configuredModelName: "sonnet")

        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.visibleRowCount, 3)
        XCTAssertEqual(model.rows[0].choice, .configured)
        XCTAssertEqual(model.rows[0].title, "Configured default")
        XCTAssertEqual(model.rows[0].subtitle, "sonnet")
        XCTAssertEqual(model.rows[1].choice, .cliDefault)
        XCTAssertEqual(model.rows[1].title, "Full model")
        XCTAssertEqual(model.rows[1].subtitle, "your Claude Code default")
        XCTAssertEqual(model.rows[2].choice, .named("opus"))
        XCTAssertEqual(model.rows[2].title, "opus")
        XCTAssertEqual(model.rows[2].subtitle, "heavyweight one-off")
    }

    /// The "Configured default" subtitle shows the ACTUAL Settings model;
    /// with none set it says so instead of pretending.
    func testConfiguredRowSubtitleFallsBackWhenNoModelIsSet() {
        let model = ModelChoiceModel()
        model.activate(configuredModelName: nil)
        XCTAssertEqual(model.rows[0].subtitle, "none set")
    }

    func testSelectionStartsAtTopAndWrapsBothWays() {
        let model = ModelChoiceModel()
        model.activate(configuredModelName: "sonnet")
        XCTAssertEqual(model.highlightIndex, 0)
        XCTAssertEqual(model.selectedChoice, .configured)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedChoice, .cliDefault)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedChoice, .named("opus"))
        model.moveSelection(by: 1) // ↓ from the last row wraps to the first
        XCTAssertEqual(model.selectedChoice, .configured)
        model.moveSelection(by: -1) // ↑ from the first wraps to the last
        XCTAssertEqual(model.selectedChoice, .named("opus"))
    }

    func testMoveSelectionWhileInactiveIsANoOp() {
        let model = ModelChoiceModel()
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(model.selectedChoice)
    }

    func testDeactivateResetsSelectionAndRows() {
        let model = ModelChoiceModel()
        model.activate(configuredModelName: "sonnet")
        model.moveSelection(by: 2)
        XCTAssertEqual(model.highlightIndex, 2)

        model.deactivate()

        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(model.selectedChoice)

        // Re-activation starts fresh at the top.
        model.activate(configuredModelName: nil)
        XCTAssertEqual(model.highlightIndex, 0)
        XCTAssertEqual(model.selectedChoice, .configured)
    }
}
