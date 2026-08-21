// The /changes pane's state (§5). Mirrors ResumePickerModel deliberately: the
// open-state pane is an established shape here — the /resume picker, the ⌘↩
// model chooser and the slash-suggestion list are all the same thing — and a
// fourth instance should be recognisable as one, not inventive.
//
// Logic lives here rather than in the App layer for the reason CLAUDE.md gives:
// App/ has no test target, so a rule that lives there is a rule nothing can
// verify. Human QA found five bugs in App-layer decisions for exactly that.

import Foundation
import Observation

@MainActor
@Observable
public final class RunChangesModel {
    /// Rows visible at once. The window is a hard 200 pt (§4); at 22 pt a row
    /// and 120 pt of base shape, six rows is what fits.
    public static let maxVisibleRows = 6

    public private(set) var isActive = false
    public private(set) var rows: [RunReceipt.Row] = []
    /// Highlighted row. Selection here is for scrolling and readability only —
    /// unlike the picker, no row does anything when chosen.
    public private(set) var selectedIndex = 0

    public init() {}

    /// Shows a receipt. An empty one still activates, so `/changes` after a run
    /// that changed nothing says so rather than silently doing nothing.
    public func activate(receipt: RunReceipt?) {
        rows = receipt?.rows() ?? []
        selectedIndex = 0
        isActive = true
    }

    public func deactivate() {
        isActive = false
        rows = []
        selectedIndex = 0
    }

    public var isEmpty: Bool {
        rows.isEmpty
    }

    /// What the view draws when there is nothing to show.
    public var emptyMessage: String {
        "Nothing to show — no run has changed anything this session"
    }

    /// Feeds `IslandView.shapeSize`, so it must never exceed `maxVisibleRows`
    /// or the drawn shape and the click hit-test disagree.
    public var visibleRowCount: Int {
        min(max(rows.count, 1), Self.maxVisibleRows)
    }

    public var highlightIndex: Int {
        min(selectedIndex, max(rows.count - 1, 0))
    }

    /// Wraps at both ends, matching the picker and the chooser.
    public func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let count = rows.count
        selectedIndex = ((highlightIndex + delta) % count + count) % count
    }
}
