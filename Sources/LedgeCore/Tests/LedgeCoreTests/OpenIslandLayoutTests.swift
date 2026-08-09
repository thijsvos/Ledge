import CoreGraphics
import LedgeCore
import XCTest

/// OpenIslandLayout.compute: the open shape's height/row split for the
/// wrapping capture field. Constants mirror the real suggestion-list call
/// site (base 120, row 22, max 200 — the constant expanded window height);
/// one extra wrapped field line ≈ 19 pt at the field's 15 pt font. The truth
/// table pins that with a one-line field the results are byte-identical to
/// the pre-wrap formula `min(base + rows × 22, 200)`, and that a grown field
/// always wins the budget: rows shrink (to 0 if needed) so the field is
/// never clipped, and a pathological measurement is clamped to `max − base`.
final class OpenIslandLayoutTests: XCTestCase {
    private let rowHeight: CGFloat = 22
    private let base: CGFloat = 120
    private let max: CGFloat = 200

    private func compute(
        extra: CGFloat, rows: Int
    ) -> (shapeHeight: CGFloat, visibleRows: Int) {
        OpenIslandLayout.compute(
            fieldExtraHeight: extra,
            requestedRows: rows,
            rowHeight: rowHeight,
            baseHeight: base,
            maxHeight: max
        )
    }

    private func assertPlan(
        extra: CGFloat, rows: Int,
        height: CGFloat, visible: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let plan = compute(extra: extra, rows: rows)
        XCTAssertEqual(plan.shapeHeight, height, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(plan.visibleRows, visible, file: file, line: line)
    }

    // MARK: - One-line field (extra 0): byte-identical to the pre-wrap formula

    func testOneLineFieldMatchesPreWrapFormulaForEveryRowCount() {
        // min(120 + rows × 22, 200) — including the tolerated 4-row 208 → 200
        // cap that base-height slack absorbs.
        assertPlan(extra: 0, rows: 0, height: 120, visible: 0)
        assertPlan(extra: 0, rows: 1, height: 142, visible: 1)
        assertPlan(extra: 0, rows: 2, height: 164, visible: 2)
        assertPlan(extra: 0, rows: 3, height: 186, visible: 3)
        assertPlan(extra: 0, rows: 4, height: 200, visible: 4) // capped from 208
        assertPlan(extra: 0, rows: 5, height: 200, visible: 5) // capped from 230
    }

    // MARK: - Two-line field (extra 19)

    func testTwoLineFieldKeepsRowsThatStillFitUnderTheCap() {
        // Room below max for an r-row shape: 80 − 22r → r ≤ 2 fits 19 pt.
        assertPlan(extra: 19, rows: 0, height: 139, visible: 0)
        assertPlan(extra: 19, rows: 1, height: 161, visible: 1)
        assertPlan(extra: 19, rows: 2, height: 183, visible: 2)
        assertPlan(extra: 19, rows: 3, height: 183, visible: 2) // 3rd row yields to the field
        assertPlan(extra: 19, rows: 4, height: 183, visible: 2)
        assertPlan(extra: 19, rows: 5, height: 183, visible: 2)
    }

    // MARK: - Three-line field (extra 38)

    func testThreeLineFieldLeavesRoomForOneRow() {
        assertPlan(extra: 38, rows: 0, height: 158, visible: 0)
        assertPlan(extra: 38, rows: 1, height: 180, visible: 1)
        assertPlan(extra: 38, rows: 2, height: 180, visible: 1)
        assertPlan(extra: 38, rows: 3, height: 180, visible: 1)
        assertPlan(extra: 38, rows: 4, height: 180, visible: 1)
        assertPlan(extra: 38, rows: 5, height: 180, visible: 1)
    }

    // MARK: - Five-line field (extra 76): rows exhausted before the field

    func testTallFieldHidesEveryRowBeforeClippingItself() {
        // Budget exhaustion order: ALL rows disappear (visible 0) while the
        // field's 76 pt still renders in full — 196 ≤ 200, unclipped.
        for rows in 0 ... 5 {
            assertPlan(extra: 76, rows: rows, height: 196, visible: 0)
        }
    }

    // MARK: - Pathological measurements

    func testFieldExtraIsClampedToTheWindowBudget() {
        // max − base = 80: a 100 pt (or absurd 10 000 pt) measurement can
        // never push the field past the constant window.
        assertPlan(extra: 100, rows: 3, height: 200, visible: 0)
        assertPlan(extra: 10000, rows: 5, height: 200, visible: 0)
    }

    func testNegativeMeasurementIsGuardedToZero() {
        assertPlan(extra: -5, rows: 4, height: 200, visible: 4)
        assertPlan(extra: -1000, rows: 2, height: 164, visible: 2)
    }

    func testNonFiniteMeasurementsAreGuardedToZero() {
        assertPlan(extra: .nan, rows: 4, height: 200, visible: 4)
        assertPlan(extra: .infinity, rows: 2, height: 164, visible: 2)
        assertPlan(extra: -.infinity, rows: 1, height: 142, visible: 1)
    }

    func testNegativeRequestedRowsAreTreatedAsZero() {
        assertPlan(extra: 0, rows: -3, height: 120, visible: 0)
        assertPlan(extra: 19, rows: -1, height: 139, visible: 0)
    }

    // MARK: - Picker geometry (base 90: the 5-row 90 + 110 = 200 exact fit)

    func testPickerBaseFitsAllFiveRowsWithAOneLineField() {
        let plan = OpenIslandLayout.compute(
            fieldExtraHeight: 0, requestedRows: 5, rowHeight: 22, baseHeight: 90, maxHeight: 200
        )
        XCTAssertEqual(plan.shapeHeight, 200, accuracy: 0.001)
        XCTAssertEqual(plan.visibleRows, 5)
    }

    func testPickerYieldsExactlyOneRowToATwoLineField() {
        // Room below max for r picker rows: 110 − 22r → r ≤ 4 fits 19 pt.
        let plan = OpenIslandLayout.compute(
            fieldExtraHeight: 19, requestedRows: 5, rowHeight: 22, baseHeight: 90, maxHeight: 200
        )
        XCTAssertEqual(plan.shapeHeight, 197, accuracy: 0.001)
        XCTAssertEqual(plan.visibleRows, 4)
    }
}

/// OpenLayoutModel: the measured-height holder CaptureView publishes into and
/// both shapeSize consumers read from. @MainActor like the model itself.
@MainActor
final class OpenLayoutModelTests: XCTestCase {
    func testExtraIsZeroWithoutAnyMeasurement() {
        XCTAssertEqual(OpenLayoutModel().fieldExtraHeight, 0)
    }

    func testEmptyFieldMeasurementCapturesTheSingleLineReference() {
        let model = OpenLayoutModel()
        model.recordFieldHeight(21, fieldIsEmpty: true)
        XCTAssertEqual(model.singleLineFieldHeight, 21)
        XCTAssertEqual(model.fieldExtraHeight, 0) // one line == no growth
    }

    func testExtraIsMeasuredMinusSingleLine() {
        let model = OpenLayoutModel()
        model.recordFieldHeight(21, fieldIsEmpty: true)
        model.recordFieldHeight(59, fieldIsEmpty: false)
        XCTAssertEqual(model.fieldExtraHeight, 38)
    }

    func testExtraStaysZeroWithoutASingleLineReference() {
        // Pathological: the field was never seen empty (e.g. restored
        // multi-line input on a fresh process) — no reference, no growth.
        let model = OpenLayoutModel()
        model.recordFieldHeight(59, fieldIsEmpty: false)
        XCTAssertEqual(model.fieldExtraHeight, 0)
    }

    func testShrinkingBelowTheReferenceNeverGoesNegative() {
        let model = OpenLayoutModel()
        model.recordFieldHeight(21, fieldIsEmpty: true)
        model.recordFieldHeight(20.5, fieldIsEmpty: false) // sub-pixel wobble
        XCTAssertEqual(model.fieldExtraHeight, 0)
    }

    func testNonFiniteAndNonPositiveMeasurementsAreDiscarded() {
        let model = OpenLayoutModel()
        model.recordFieldHeight(21, fieldIsEmpty: true)
        model.recordFieldHeight(59, fieldIsEmpty: false)
        model.recordFieldHeight(.nan, fieldIsEmpty: false)
        model.recordFieldHeight(.infinity, fieldIsEmpty: false)
        model.recordFieldHeight(-4, fieldIsEmpty: true)
        model.recordFieldHeight(0, fieldIsEmpty: true)
        XCTAssertEqual(model.measuredFieldHeight, 59)
        XCTAssertEqual(model.singleLineFieldHeight, 21)
        XCTAssertEqual(model.fieldExtraHeight, 38)
    }

    func testEmptyFieldMeasurementRecapturesTheReference() {
        let model = OpenLayoutModel()
        model.recordFieldHeight(21, fieldIsEmpty: true)
        model.recordFieldHeight(59, fieldIsEmpty: false)
        model.recordFieldHeight(22, fieldIsEmpty: true) // e.g. text cleared
        XCTAssertEqual(model.singleLineFieldHeight, 22)
        XCTAssertEqual(model.fieldExtraHeight, 0)
    }

    func testResetDropsTheMeasurementButKeepsTheReference() {
        let model = OpenLayoutModel()
        model.recordFieldHeight(21, fieldIsEmpty: true)
        model.recordFieldHeight(59, fieldIsEmpty: false)
        model.reset()
        XCTAssertEqual(model.measuredFieldHeight, 0)
        XCTAssertEqual(model.fieldExtraHeight, 0) // fresh open starts at base
        XCTAssertEqual(model.singleLineFieldHeight, 21) // survives the open
        // The next open's restored multi-line input still grows the shape.
        model.recordFieldHeight(40, fieldIsEmpty: false)
        XCTAssertEqual(model.fieldExtraHeight, 19)
    }
}
