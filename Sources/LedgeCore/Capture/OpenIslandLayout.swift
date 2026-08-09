// Open-island height budget for the wrapping capture field. Lives in
// LedgeCore — not the UI target — because this one function decides the
// number three call sites must agree on: IslandView's drawn shape, the row
// budget the suggestion/picker lists render inside it, and
// NotchWindowController's click-outside hit-test. A mismatch between drawing
// and hit-testing means clicks near the grown field's bottom edge fall
// through or dead-zone (a class of bug that has bitten review before), so
// the arithmetic is pure, shared, and unit-tested here. CoreGraphics only
// (CGFloat — the same precedent as Geometry); no AppKit, no SwiftUI.

import CoreGraphics
import Foundation

/// Pure open-state layout math: how tall the black shape is and how many
/// list rows still fit once the capture field has wrapped onto extra lines.
public enum OpenIslandLayout {
    /// Splits the open shape's height budget between the capture field and
    /// the suggestion/picker list.
    ///
    /// `shapeHeight = min(baseHeight + fieldExtra + visibleRows × rowHeight,
    /// maxHeight)`, where the FIELD wins the budget: `visibleRows` shrinks
    /// from `requestedRows` (to 0 if needed) until the field's extra height
    /// fits in the room an r-row shape leaves below `maxHeight` — field
    /// growth is never clipped. Two guards keep pathological measurements
    /// harmless: a non-finite or negative `fieldExtraHeight` is treated as 0,
    /// and the extra is clamped to `maxHeight − baseHeight` so no measurement
    /// can push the field past the constant window.
    ///
    /// With `fieldExtraHeight == 0` every requested row survives and the
    /// result is byte-identical to the pre-wrap formula
    /// `min(base + rows × rowHeight, max)` — including the tolerated overshoot
    /// cap (e.g. the suggestion list's 4-row 208 → 200), which base-height
    /// slack absorbs. That overshoot tolerance never applies while the field
    /// is grown: for `fieldExtraHeight > 0` the chosen rows satisfy
    /// `base + fieldExtra + rows × rowHeight ≤ max` exactly.
    ///
    /// - Parameters:
    ///   - fieldExtraHeight: measured field height minus its one-line height
    ///     (`OpenLayoutModel.fieldExtraHeight`).
    ///   - requestedRows: rows the active list wants (already capped by the
    ///     model's `maxVisibleRows`); negative values are treated as 0.
    ///   - rowHeight: one list row's fixed height.
    ///   - baseHeight: the open shape's height with a one-line field and no
    ///     rows (120 for suggestions, 90 for the picker).
    ///   - maxHeight: the constant expanded window height (the shape can
    ///     never exceed the window).
    public static func compute(
        fieldExtraHeight: CGFloat,
        requestedRows: Int,
        rowHeight: CGFloat,
        baseHeight: CGFloat,
        maxHeight: CGFloat
    ) -> (shapeHeight: CGFloat, visibleRows: Int) {
        let guarded = fieldExtraHeight.isFinite ? max(0, fieldExtraHeight) : 0
        let fieldExtra = min(guarded, max(0, maxHeight - baseHeight))
        var rows = max(0, requestedRows)
        while rows > 0, fieldExtra > max(0, maxHeight - baseHeight - CGFloat(rows) * rowHeight) {
            rows -= 1
        }
        let shapeHeight = min(baseHeight + fieldExtra + CGFloat(rows) * rowHeight, maxHeight)
        return (shapeHeight, rows)
    }
}
