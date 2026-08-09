// Slash-command typeahead state (user-requested addition beyond the MVP
// spec). Lives in LedgeCore — not the UI target — because the query
// tokenization, wrap-around selection arithmetic, and the Enter
// complete-vs-raw-submit policy decide exactly what string reaches
// CaptureCoordinator, and CLAUDE.md wants all such logic unit-testable.
// Observation-only (no SwiftUI): the same import set IslandController
// already uses.
//
// SOURCE: the list shows LEDGE'S OWN native commands (`NativeCommand`, a
// static list in declaration order) — NOT the user's Claude Code catalog.
// The catalog scan still runs per open, but it feeds only the invisible
// submit-time slash restoration (see NotchWindowController /
// CaptureCoordinator): typed Claude commands keep working; they just aren't
// suggested here.
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
/// The source is the static `NativeCommand` list; everything here is derived
/// per keystroke from `text` — there is nothing to poll and nothing to scan.
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
    /// defensive only now that the source is static, but harmless.
    public private(set) var selectedIndex = 0
    /// True once the user pressed ↓/↑ for the current text. See
    /// `shouldCompleteOnReturn` — an active selection always renders the
    /// highlight and always makes Enter run that row.
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

    /// Native commands matching the typed token, in `NativeCommand`
    /// declaration order (documented choice — NOT alphabetical).
    public var matches: [NativeCommand] {
        guard let query else { return [] }
        return NativeCommand.matching(prefix: query)
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

    public var selectedCommand: NativeCommand? {
        let matches = matches
        guard !matches.isEmpty else { return nil }
        return matches[min(selectedIndex, matches.count - 1)]
    }

    /// Enter completes-then-submits when the user actively chose a row with
    /// ↓/↑, OR when a REAL query (non-empty token) has exactly one match —
    /// with a short static list, "/q" + Enter running /quit is unambiguous.
    /// The bare "/" (empty query) NEVER auto-completes: it matches the whole
    /// list, and "/" + Enter must never silently run a command.
    ///
    /// `SlashSuggestionList` renders the highlight from this same condition,
    /// so a highlighted row always means exactly "Enter runs this" and an
    /// un-highlighted list always means "Enter submits the raw text".
    public var shouldCompleteOnReturn: Bool {
        guard isListVisible else { return false }
        if hasUserMovedSelection {
            return true
        }
        guard let query, !query.isEmpty else { return false }
        return matches.count == 1
    }

    /// What Enter would do RIGHT NOW: the highlighted native row whenever
    /// `shouldCompleteOnReturn` (the key monitor then completes "/name " and
    /// submits it — see NotchWindowController), else whatever the raw text
    /// routes to. The capture view's target chip MUST render from this, not
    /// from `SubmitAction.decide(text)` alone — for "/q" decide says
    /// .agent("q") while Enter actually runs /quit, and the chip must never
    /// lie precisely when Enter is destructive.
    public var submitActionOnReturn: SubmitAction {
        if shouldCompleteOnReturn, let selectedCommand {
            return .native(selectedCommand)
        }
        return SubmitAction.decide(text)
    }

    /// ↓ (+1) / ↑ (−1). The selection WRAPS at both ends (documented choice:
    /// ↓ from the last row returns to the first, ↑ from the first to the
    /// last) — with scrollable lists, wrapping beats pinning against an
    /// invisible end.
    public func moveSelection(by delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        let current = min(selectedIndex, count - 1)
        selectedIndex = (current + delta % count + count) % count
        hasUserMovedSelection = true
    }

    /// What completion puts in the field: "/name " — the trailing space hides
    /// the list (a space after the token ends the query), and submit-time
    /// `NativeCommand.match` trims it, so the completed text still executes
    /// natively. Replacing the whole field text puts the caret at the end.
    public func completionText(for command: NativeCommand) -> String {
        "/" + command.name + " "
    }

    /// Tab and row clicks: complete into the field WITHOUT submitting.
    public func complete(_ command: NativeCommand) {
        text = completionText(for: command)
    }

    public func completeSelection() {
        guard let selectedCommand else { return }
        complete(selectedCommand)
    }
}
