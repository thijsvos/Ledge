// Slash-command typeahead state (user-requested addition beyond the MVP
// spec). Lives in LedgeCore — not the UI target — because the query
// tokenization, wrap-around selection arithmetic, and the Enter
// complete-vs-raw-submit policy decide exactly what string reaches
// CaptureCoordinator, and CLAUDE.md wants all such logic unit-testable.
// Observation-only (no SwiftUI): the same import set IslandController
// already uses.
//
// The App layer owns the single instance: NotchWindowController's LOCAL key
// monitor drives selection and completion, CaptureView's TextField binds
// `text`, and SlashSuggestionList renders `matches`. Deliberately NOT part
// of `IslandController` — the island state machine is untouched by this
// feature; this is field-local UI state.

import Foundation
import Observation

/// Typeahead state for the capture field's slash-command suggestions.
///
/// The catalog is replaced after each scan (one scan per transition into
/// `.open`, off the main actor — see the window controller). Everything else
/// here is derived per keystroke from `text`; there is nothing to poll.
@MainActor
@Observable
public final class SlashSuggestionModel {
    /// Rows the list shows at most; more matches scroll within them. 4 is a
    /// hard content budget, not taste: the open overlay stacks the notch
    /// clearance (~40 pt), the field row, the hint line, and the list inside
    /// the CONSTANT 200 pt window (§4 — the NSWindow never resizes), and
    /// 4 × 22 pt rows are the most that fit without the bottom row clipping
    /// at the window edge (5 rows need ≥ 205 pt of un-compressible content).
    public static let maxVisibleRows = 4

    /// The scanned commands; replaced by the window controller when a scan
    /// lands. Starts empty, so the list simply doesn't show until then.
    public var catalog = SlashCommandCatalog()

    /// The capture field's live text (single source of truth — CaptureView
    /// binds its TextField here so the key monitor can complete into the
    /// field). Any edit resets the selection to the top.
    public var text = "" {
        didSet {
            guard text != oldValue else { return }
            selectedIndex = 0
            hasUserMovedSelection = false
        }
    }

    /// Keyboard selection into `matches`. Clamp on read (`highlightIndex`) —
    /// matches can shrink under it while the user types.
    public private(set) var selectedIndex = 0
    /// True once the user pressed ↓/↑ for the current text. The selection
    /// highlight renders ONLY while this is true, and Enter
    /// completes-then-submits ONLY while this is true — the visible
    /// highlight and the Enter behavior always agree (highlight shown ⇔
    /// Enter runs that row).
    public private(set) var hasUserMovedSelection = false

    public init() {}

    /// The command token being typed: the text between "/" and the first
    /// space. Nil without the "/" prefix, and nil once a space follows the
    /// token (the user is past the name — the list hides).
    public var query: String? {
        guard text.hasPrefix("/") else { return nil }
        let token = text.dropFirst()
        guard !token.contains(" ") else { return nil }
        return String(token)
    }

    public var matches: [SlashCommand] {
        guard let query else { return [] }
        return catalog.matching(prefix: query)
    }

    public var isListVisible: Bool {
        !matches.isEmpty
    }

    /// Rows the list actually shows (≤ `maxVisibleRows`; more scroll within
    /// them). Feeds `IslandView.shapeSize` so the open shape grows with the
    /// list.
    public var visibleRowCount: Int {
        min(matches.count, Self.maxVisibleRows)
    }

    /// `selectedIndex` clamped into `matches`.
    public var highlightIndex: Int {
        min(selectedIndex, max(matches.count - 1, 0))
    }

    public var selectedCommand: SlashCommand? {
        let matches = matches
        guard !matches.isEmpty else { return nil }
        return matches[min(selectedIndex, matches.count - 1)]
    }

    /// Enter completes-then-submits only when the user actively chose a row
    /// with ↓/↑ — the same condition that renders the highlight, so what is
    /// visibly selected is exactly what Enter runs. Otherwise Enter submits
    /// the raw text exactly as before this feature.
    ///
    /// Deliberately NO single-match auto-complete: with one command
    /// installed, "/" + Enter must never silently launch it (the empty query
    /// matches the whole catalog), and "/fix" + Enter must submit "fix" —
    /// not a lone "fix-ci" match the user never typed.
    public var shouldCompleteOnReturn: Bool {
        isListVisible && hasUserMovedSelection
    }

    /// ↓ (+1) / ↑ (−1). The selection WRAPS at both ends (documented choice:
    /// ↓ from the last row returns to the first, ↑ from the first to the
    /// last) — with long scrollable lists, wrapping beats pinning against an
    /// invisible end.
    public func moveSelection(by delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        let current = min(selectedIndex, count - 1)
        selectedIndex = (current + delta % count + count) % count
        hasUserMovedSelection = true
    }

    /// What completion puts in the field: "/name " — the trailing space both
    /// lets arguments follow immediately and hides the list (a space after
    /// the token ends the query). Replacing the whole field text puts the
    /// caret at the end.
    public func completionText(for command: SlashCommand) -> String {
        "/" + command.name + " "
    }

    /// Tab and row clicks: complete into the field WITHOUT submitting.
    public func complete(_ command: SlashCommand) {
        text = completionText(for: command)
    }

    public func completeSelection() {
        guard let selectedCommand else { return }
        complete(selectedCommand)
    }
}
