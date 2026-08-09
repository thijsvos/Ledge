import LedgeCore
import SwiftUI

/// The open-state capture UI (§5): one text field, a subtle `/` hint, and a
/// target chip that live-updates from `CaptureRouter` as the user types —
/// plus, while the text is a bare `/command` token, the slash-command
/// typeahead list (SlashSuggestionList).
///
/// Enter hands the raw input to the coordinator via `onSubmit` and clears the
/// field; the coordinator performs the write synchronously (<5 ms in practice)
/// and collapses the island into the resulting peek immediately — the field is
/// never blocked on I/O. If the capture FAILS, the coordinator keeps the raw
/// input and `restoreInput` refills the field on the next open — typed text is
/// never lost to a failure peek. Esc handling is unchanged from Phase 1 (the
/// window controller's key monitor dismisses the open island).
///
/// The field's text lives in `SlashSuggestionModel` (owned by the window
/// controller, whose key monitor completes into the field); each appearance
/// resets it from `restoreInput`, so a dismissed island still discards its
/// text exactly as when the text was view-local @State.
struct CaptureView: View {
    /// Points the top spacer clears so content starts below the physical notch.
    var topClearance: CGFloat
    /// ImageRenderer cannot rasterize the AppKit-backed TextField;
    /// --render-preview sets this to draw a static stand-in instead (§9).
    /// The static branch renders NO suggestion UI — previews are unchanged.
    var staticRendering: Bool
    /// Called with the raw field contents on Enter.
    var onSubmit: (String) -> Void
    /// Queried once when the field appears: non-nil after a failed capture
    /// (the coordinator preserves what the user typed — text is never lost
    /// to a failure peek).
    var restoreInput: () -> String? = { nil }
    /// The controller-owned typeahead model. Nil (e.g. --render-preview's
    /// bare `IslandView(state:)`) falls back to an inert view-local model
    /// with an empty catalog — no suggestions, field still works.
    var suggestionModel: SlashSuggestionModel?

    @State private var fallbackModel = SlashSuggestionModel()
    @FocusState private var fieldFocused: Bool

    private var model: SlashSuggestionModel {
        suggestionModel ?? fallbackModel
    }

    private static let placeholder = "Capture a thought…"
    private static let hint = "↩ save · / agent · .i inbox"

    /// "daily" / "inbox" / "agent" / "ledge", from the model's
    /// `submitActionOnReturn` — the SAME condition the key monitor and the
    /// list highlight use, `SubmitAction.decide` included. Deriving the chip
    /// from `decide(text)` alone would lie exactly when it matters most:
    /// for "/q" decide says .agent("q") but Enter auto-completes the single
    /// match and runs /quit (LedgeCore-tested seam, so the chip and Enter
    /// can never diverge).
    private var targetLabel: String {
        switch model.submitActionOnReturn {
        case .native:
            "ledge"
        case .routed(.agent):
            "agent"
        case let .routed(.instant(target, _)):
            target == .inbox ? "inbox" : "daily"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: topClearance)
            HStack(spacing: 12) {
                if staticRendering {
                    Text(Self.placeholder)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(Self.placeholder, text: Bindable(model).text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                }
                targetChip
            }
            Text(Self.hint)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
            if !staticRendering, model.isListVisible {
                SlashSuggestionList(model: model)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear {
            // Fresh field per open (matching the old @State behavior);
            // restore fills it only after a failed capture.
            model.text = restoreInput() ?? ""
            fieldFocused = true
        }
    }

    private var targetChip: some View {
        Text(targetLabel)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.12)))
    }

    private func submit() {
        let input = model.text
        model.text = "" // §5: the field clears after submit
        onSubmit(input)
    }
}
