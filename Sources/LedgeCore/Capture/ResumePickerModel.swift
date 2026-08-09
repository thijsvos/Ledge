// /resume session-picker state, mirroring SlashSuggestionModel's shape: the
// model lives in LedgeCore (filtering, wrap-around selection, and the
// validity rule deciding which recorded runs are offered are all
// unit-testable here), the UI target only renders it (ResumePickerList), and
// the App layer's ONE local key monitor drives the selection. Observation
// only — no SwiftUI, the same import set IslandController already uses.
//
// Picker mode is VIEW-MODEL STATE, not an island state: while active the
// island simply stays `.open` (IslandState untouched;
// `IslandController.transition(to:)` remains the sole mutation point) and
// CaptureView renders this list instead of the slash suggestions.

import Foundation
import Observation

/// State for the /resume picker inside the open island.
@MainActor
@Observable
public final class ResumePickerModel {
    /// Rows the list shows at most; more matches scroll within them. 5 fits
    /// because picker mode hides the capture hint line (the field placeholder
    /// carries the instructions instead): clearance + field row + 5 × 22 pt
    /// rows stay inside the constant 200 pt window (§4 — the NSWindow never
    /// resizes). Compare `SlashSuggestionModel.maxVisibleRows` (4), which
    /// must coexist with the hint line.
    public static let maxVisibleRows = 5

    /// True while the open island is in picker mode. Set only via
    /// `activate(records:seededLastSession:)` / `deactivate()`.
    public private(set) var isActive = false

    /// True when the offered rows are not recorded history but the single
    /// seeded fallback built from the stored per-vault lastSessionID.
    /// UserDefaults keeps ONLY the ID — when that session ran and how it
    /// ended are unknown — so the UI must render the row neutrally (no
    /// relative time, no outcome glyph) instead of the fabricated
    /// date/outcome the placeholder record carries.
    public private(set) var isSeededFallback = false

    /// The offered sessions, newest first — only records that carry a
    /// non-nil, `ResumeScriptWriter`-valid session ID (the same guard the
    /// resume script enforces before any interpolation) survive activation.
    public private(set) var records: [RunRecord] = []

    /// The filter field's live text (the capture field binds here while the
    /// picker is active). Any edit resets the selection to the top.
    public var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            selectedIndex = 0
        }
    }

    /// Keyboard selection into `filteredRecords`; clamped on read.
    public private(set) var selectedIndex = 0

    public init() {}

    /// The records /resume may offer: non-nil session ID that passes the
    /// exact `ResumeScriptWriter` validity rule (`^[A-Za-z0-9-]+$`). Static
    /// so the App layer can test-for-empty BEFORE deciding to activate.
    public static func resumableRecords(_ records: [RunRecord]) -> [RunRecord] {
        records.filter { record in
            guard let sessionID = record.sessionID else { return false }
            return ResumeScriptWriter.isValidSessionID(sessionID)
        }
    }

    /// Enters picker mode with the given records (validity-filtered here
    /// again — activation is safe with any input) and a fresh filter and
    /// selection. `seededLastSession` marks the stored-lastSessionID
    /// fallback row (see `isSeededFallback`).
    public func activate(records: [RunRecord], seededLastSession: Bool = false) {
        self.records = Self.resumableRecords(records)
        isSeededFallback = seededLastSession
        filterText = ""
        selectedIndex = 0
        isActive = true
    }

    /// Leaves picker mode and drops all state — reopening the island later
    /// starts in normal capture mode.
    public func deactivate() {
        isActive = false
        isSeededFallback = false
        records = []
        filterText = ""
        selectedIndex = 0
    }

    /// Case-insensitive substring filter over the prompt; the empty filter
    /// shows everything. Order (newest first) is preserved.
    public var filteredRecords: [RunRecord] {
        guard !filterText.isEmpty else { return records }
        return records.filter {
            $0.prompt.range(of: filterText, options: .caseInsensitive) != nil
        }
    }

    /// Rows the list actually shows (≤ `maxVisibleRows`; more scroll within
    /// them). Feeds `IslandView.shapeSize` so the open shape grows with the
    /// list.
    public var visibleRowCount: Int {
        min(filteredRecords.count, Self.maxVisibleRows)
    }

    /// `selectedIndex` clamped into `filteredRecords`.
    public var highlightIndex: Int {
        min(selectedIndex, max(filteredRecords.count - 1, 0))
    }

    /// The record Enter resumes right now (the highlighted row; defaults to
    /// the newest). Nil when the filter matches nothing — Enter then does
    /// nothing.
    public var selectedRecord: RunRecord? {
        let filtered = filteredRecords
        guard !filtered.isEmpty else { return nil }
        return filtered[min(selectedIndex, filtered.count - 1)]
    }

    /// ↓ (+1) / ↑ (−1); wraps at both ends, exactly like the slash
    /// suggestions (documented choice — with scrollable lists, wrapping
    /// beats pinning against an invisible end).
    public func moveSelection(by delta: Int) {
        let count = filteredRecords.count
        guard count > 0 else { return }
        let current = min(selectedIndex, count - 1)
        selectedIndex = (current + delta % count + count) % count
    }
}
