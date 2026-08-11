// ⌘↩ per-run model chooser state, mirroring ResumePickerModel's shape: the
// model lives in LedgeCore (row construction and wrap-around selection are
// unit-testable here), the UI target only renders it (ModelChoiceList), and
// the App layer's ONE local key monitor drives the selection. Observation
// only — no SwiftUI, the same import set the sibling models use.
//
// Chooser mode is VIEW-MODEL STATE, not an island state: while active the
// island simply stays `.open` (IslandState untouched;
// `IslandController.transition(to:)` remains the sole mutation point) and
// CaptureView renders this list instead of the slash suggestions (the resume
// picker still wins over everything).
//
// The row set is FIXED by design: the configured Settings default, the
// user's own Claude Code default (no --model flag), and a one-off "opus".
// Deliberately absent, per explicit user requirement: any small/cheap model
// row, and any effort row — effort is not part of this chooser and the
// configured effort applies to every choice.

import Foundation
import Observation

/// State for the ⌘↩ per-run model chooser inside the open island.
@MainActor
@Observable
public final class ModelChoiceModel {
    /// The chooser always offers exactly its three fixed rows; the cap only
    /// feeds the shared open-shape row budget (`IslandView.openPlan`), where
    /// a wrap-grown capture field may still shrink what is rendered.
    public static let maxVisibleRows = 3

    /// True while the open island is in chooser mode. Set only via
    /// `activate(configuredModelName:)` / `deactivate()`.
    public private(set) var isActive = false

    /// The offered choices, in presentation order. Built by `activate` —
    /// empty while inactive.
    public private(set) var rows: [(choice: RunModelChoice, title: String, subtitle: String)] = []

    /// Keyboard selection into `rows`; clamped on read (`highlightIndex`).
    public private(set) var selectedIndex = 0

    public init() {}

    /// Enters chooser mode with a fresh selection. `configuredModelName` is
    /// the actual Settings model (already sanitized by the App layer); nil
    /// renders the "Configured default" row's subtitle as "none set".
    public func activate(configuredModelName: String?) {
        rows = [
            (.configured, "Configured default", configuredModelName ?? "none set"),
            (.cliDefault, "Full model", "your Claude Code default"),
            (.named("opus"), "opus", "heavyweight one-off"),
        ]
        selectedIndex = 0
        isActive = true
    }

    /// Leaves chooser mode and drops all state — the next activation starts
    /// at the top again.
    public func deactivate() {
        isActive = false
        rows = []
        selectedIndex = 0
    }

    /// Rows the list actually shows (≤ `maxVisibleRows`). Feeds
    /// `IslandView.shapeSize` so the open shape grows with the list.
    public var visibleRowCount: Int {
        min(rows.count, Self.maxVisibleRows)
    }

    /// `selectedIndex` clamped into `rows`.
    public var highlightIndex: Int {
        min(selectedIndex, max(rows.count - 1, 0))
    }

    /// The choice Enter submits right now (the highlighted row; defaults to
    /// the first). Nil while inactive — Enter then does nothing.
    public var selectedChoice: RunModelChoice? {
        guard !rows.isEmpty else { return nil }
        return rows[min(selectedIndex, rows.count - 1)].choice
    }

    /// ↓ (+1) / ↑ (−1); wraps at both ends, exactly like the slash
    /// suggestions and the resume picker (documented choice).
    public func moveSelection(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        let current = min(selectedIndex, count - 1)
        selectedIndex = (current + delta % count + count) % count
    }
}
