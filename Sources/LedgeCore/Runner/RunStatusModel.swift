// Live-run status for the hover chip, mirroring OpenLayoutModel's ownership
// shape: the App layer owns the single instance; AgentRunController writes
// the run bookkeeping (prompt + start date) on the same paths that set and
// clear the island's live-run handle; NotchWindowController writes the hover
// flag from the EXISTING hover machinery; and BOTH IslandView's drawn shape
// and the window controller's click-outside hit-test read the flag from the
// same object, so the widened status chip and its hit-test can never
// disagree. Observation only — no SwiftUI, the same import set
// OpenLayoutModel already uses.

import Foundation
import Observation

/// What the running dot's hover chip shows: which prompt is live and since
/// when, plus whether the pointer currently rests on the running island.
@MainActor
@Observable
public final class RunStatusModel {
    /// Excerpt budget (~44 characters) shared by the hover chip and the
    /// start peek — long prompts are cut on a `Character` boundary and
    /// ellipsized.
    public static let excerptMaxLength = 44

    /// The live run's prompt as submitted; nil while no run is live.
    public private(set) var liveRunPrompt: String?

    /// When the live run started, wall-clock. Set at Enter for the run the
    /// user just submitted (the honest "how long have I been waiting" zero
    /// point — the runner's confirmation lags by binary resolution), and at
    /// the runner's `runStarted` for queued runs starting later.
    public private(set) var runStartDate: Date?

    /// True while the pointer rests on the island in `.running` (after the
    /// shared 80 ms hover debounce). Owned by NotchWindowController — the
    /// hover machinery sets it, pointer exit and any island-state change
    /// away from `.running` clear it. No IslandState is involved:
    /// `.running → .hover` stays illegal; this flag is view-model state only.
    public var isHoveringWhileRunning = false

    public init() {}

    /// The live prompt cut to the shared excerpt budget; "" while idle.
    public var promptExcerpt: String {
        liveRunPrompt.map { Self.excerpt(of: $0) } ?? ""
    }

    /// Records a run going live. `startDate` is kept from an earlier call
    /// when the prompt is unchanged — the provisional record made at Enter
    /// already holds the honest wall-clock zero, and the runner's
    /// `runStarted` confirmation (same prompt, seconds later) must not shift
    /// it. A different prompt (a queued run starting) restarts the clock.
    public func recordRunStart(prompt: String, startDate: Date = Date()) {
        if liveRunPrompt != prompt || runStartDate == nil {
            runStartDate = startDate
        }
        liveRunPrompt = prompt
    }

    /// Clears the run bookkeeping — called on every path that clears the
    /// live-run handle (completion, /cancel, runner retirement, and a
    /// provisional submission rejected before it ran). The hover flag is
    /// NOT touched: it belongs to the window controller, which clears it on
    /// pointer exit and on any state change away from `.running`.
    public func clear() {
        liveRunPrompt = nil
        runStartDate = nil
    }

    /// Pure excerpt helper: first `maxLength` characters (grapheme clusters,
    /// so emoji and combining sequences never split), ellipsized when cut.
    /// Newlines collapse to spaces (the chip and the start peek are
    /// single-line surfaces) and surrounding whitespace is trimmed first.
    public static func excerpt(of prompt: String, maxLength: Int = excerptMaxLength) -> String {
        let flattened = prompt
            .split(whereSeparator: \.isNewline) // Character-based: \r\n is ONE break
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > maxLength else { return flattened }
        return String(flattened.prefix(maxLength)) + "…"
    }
}
