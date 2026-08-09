// Live capture-field height for the open island, mirroring
// SlashSuggestionModel's ownership shape: the App layer
// (NotchWindowController) owns the single instance, CaptureView publishes the
// field's rendered height into it (GeometryReader background + PreferenceKey
// — no timers, no monitors), and BOTH IslandView's drawn shape and the window
// controller's click-outside hit-test read `fieldExtraHeight` from the same
// object, so the shape and its hit-test can never disagree about the grown
// field. Observation only — no SwiftUI, the same import set
// SlashSuggestionModel already uses.

import CoreGraphics
import Foundation
import Observation

/// The capture field's measured wrap growth while the island is open.
@MainActor
@Observable
public final class OpenLayoutModel {
    /// The field's rendered height with exactly one line, captured from the
    /// SAME preference stream whenever the field is reported EMPTY (an empty
    /// vertical-axis field is single-line by construction) — measured, never
    /// hardcoded. Sticky across opens: it is a property of the font and
    /// field, not of the current text, and it must survive `reset()` so an
    /// island reopened with restored multi-line input (which is never empty
    /// during that open) still has a reference to grow against. 0 until the
    /// first empty-field measurement; `fieldExtraHeight` stays 0 until then
    /// (no reference — no growth).
    public private(set) var singleLineFieldHeight: CGFloat = 0

    /// The field's last rendered height this open; 0 until the first
    /// measurement after `reset()`.
    public private(set) var measuredFieldHeight: CGFloat = 0

    public init() {}

    /// How much taller than one line the field currently is — the
    /// `fieldExtraHeight` input to `OpenIslandLayout.compute`. 0 without both
    /// a single-line reference and a live measurement; never negative.
    public var fieldExtraHeight: CGFloat {
        guard singleLineFieldHeight > 0, measuredFieldHeight > 0 else { return 0 }
        return max(0, measuredFieldHeight - singleLineFieldHeight)
    }

    /// CaptureView reports every rendered field height here (its
    /// GeometryReader preference). Non-finite or non-positive heights are
    /// discarded at the door — a broken measurement must never poison the
    /// shape. `fieldIsEmpty` is what captures (and re-captures) the
    /// single-line reference.
    public func recordFieldHeight(_ height: CGFloat, fieldIsEmpty: Bool) {
        guard height.isFinite, height > 0 else { return }
        measuredFieldHeight = height
        if fieldIsEmpty {
            singleLineFieldHeight = height
        }
    }

    /// Fresh field per open: drops the live measurement so the next open
    /// starts at the base height BEFORE the new field renders (the open shape
    /// — and the monitors' hit-test — are computed from this model before
    /// CaptureView.onAppear resets the text). Keeps the single-line
    /// reference (see `singleLineFieldHeight`).
    public func reset() {
        measuredFieldHeight = 0
    }
}
