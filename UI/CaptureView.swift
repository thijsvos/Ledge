import LedgeCore
import SwiftUI

/// The open-state capture UI (§5): one text field, a subtle `/` hint, and a
/// target chip that live-updates from `CaptureRouter` as the user types —
/// plus, while the text is a bare `/command` token, the slash-command
/// typeahead list (SlashSuggestionList), OR — while the /resume picker is
/// active — the recent-session list (ResumePickerList). Picker mode wins over
/// the suggestion list; it also replaces the placeholder ("Filter sessions —
/// Enter resumes, Esc closes"), hides the hint line (that's what buys the
/// fifth row inside the constant 200 pt window), and hides the target chip
/// (Enter resumes a session, it doesn't route a capture).
///
/// Enter hands the raw input to the coordinator via `onSubmit` and clears the
/// field; the coordinator performs the write synchronously (<5 ms in practice)
/// and collapses the island into the resulting peek immediately — the field is
/// never blocked on I/O. If the capture FAILS, the coordinator keeps the raw
/// input and `restoreInput` refills the field on the next open — typed text is
/// never lost to a failure peek. Esc handling is unchanged from Phase 1 (the
/// window controller's key monitor dismisses the open island). In picker mode
/// Enter/↑/↓ are swallowed by that same key monitor before the field ever
/// sees them.
///
/// The field's text lives in `SlashSuggestionModel` (owned by the window
/// controller, whose key monitor completes into the field) — or, while the
/// picker is active, in `ResumePickerModel.filterText`; each appearance
/// resets it from `restoreInput`, so a dismissed island still discards its
/// text exactly as when the text was view-local @State.
///
/// The field WRAPS at the right edge (`axis: .vertical`, `.lineLimit(1...4)`
/// — an empty/short field stays exactly one line, so the base open height is
/// pixel-unchanged) and grows the island downward; beyond 4 wrapped lines it
/// scrolls internally. Its rendered height is observed via a GeometryReader
/// background + PreferenceKey (no timers) and published into the
/// controller-owned `OpenLayoutModel`, which both `IslandView.shapeSize` and
/// the controller's click-outside hit-test read. Empirically verified on
/// this SDK (Xcode 26.6 / macOS 26.5): Return still SUBMITS via `onSubmit`
/// (no newline is inserted), and Option+Return inserts a literal "\n" —
/// standard AppKit behavior, no custom key handling. Wrapping is VISUAL
/// only: `InstantCapture` still flattens hard newlines to spaces, and agent
/// prompts still carry pasted newlines verbatim.
struct CaptureView: View {
    /// Points the top spacer clears so content starts below the physical notch.
    var topClearance: CGFloat
    /// ImageRenderer cannot rasterize the AppKit-backed TextField;
    /// --render-preview sets this to draw a static stand-in instead (§9).
    /// The static branch renders NO suggestion or picker UI — previews are
    /// unchanged.
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
    /// The controller-owned /resume picker model. Nil (previews) = never in
    /// picker mode.
    var pickerModel: ResumePickerModel?
    /// Row click in the picker → resume that session.
    var onPickerSelect: (RunRecord) -> Void = { _ in }
    /// Where the field's measured height is published (owned by the window
    /// controller — the same instance IslandView and the hit-test read).
    /// Nil (previews / --render-preview) = never measured, never grown.
    var openLayoutModel: OpenLayoutModel?
    /// Rows the open shape's height budget still covers, from the SAME
    /// `IslandView.openPlan` the shape is drawn with — a wrap-grown field
    /// steals row budget, and rows without budget must not be rendered (they
    /// would paint below the black shape). `.max` (previews / fallback)
    /// keeps the models' own caps as the only limit.
    var listRowLimit: Int = .max

    @State private var fallbackModel = SlashSuggestionModel()
    @FocusState private var fieldFocused: Bool

    private var model: SlashSuggestionModel {
        suggestionModel ?? fallbackModel
    }

    /// Non-nil exactly while picker mode is on (picker wins over suggestions).
    private var picker: ResumePickerModel? {
        guard let pickerModel, pickerModel.isActive else { return nil }
        return pickerModel
    }

    private static let placeholder = "Capture a thought…"
    private static let pickerPlaceholder = "Filter sessions — Enter resumes, Esc closes"
    private static let hint = "↩ save · / agent · .i inbox"

    /// "daily" / "inbox" / "agent" / "ledge", from the model's
    /// `submitActionOnReturn` — the SAME condition the key monitor and the
    /// list highlight use, `SubmitAction.decide` included. Deriving the chip
    /// from `decide(text)` alone would lie exactly when it matters most:
    /// for "/q" decide says .agent("q") while Enter actually runs /quit
    /// (LedgeCore-tested seam, so the chip and Enter can never diverge).
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

    /// The field binds to the picker's filter while picker mode is active,
    /// else to the typeahead model — one TextField, stable identity, so
    /// focus survives entering and leaving picker mode.
    private var fieldText: Binding<String> {
        if let picker {
            Bindable(picker).filterText
        } else {
            Bindable(model).text
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
                    TextField(
                        picker == nil ? Self.placeholder : Self.pickerPlaceholder,
                        text: fieldText,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 4) // no reserved space: empty/short stays one line
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .background {
                        // Observes the field's rendered height (macOS 14-safe;
                        // no timers) — collected by onPreferenceChange below.
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: CaptureFieldHeightKey.self, value: proxy.size.height
                            )
                        }
                    }
                }
                if picker == nil {
                    targetChip
                }
            }
            if picker == nil {
                Text(Self.hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            // listRowLimit == 0 (a tall wrapped field spent the whole row
            // budget) renders no list AT ALL — not even a zero-height frame,
            // whose stack spacing would still nudge the layout.
            if !staticRendering, listRowLimit > 0, let picker {
                ResumePickerList(model: picker, onSelect: onPickerSelect, rowLimit: listRowLimit)
            } else if !staticRendering, listRowLimit > 0, model.isListVisible {
                SlashSuggestionList(model: model, rowLimit: listRowLimit)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .onPreferenceChange(CaptureFieldHeightKey.self) { [openLayoutModel, model, pickerModel] height in
            // Preferences are delivered on the main thread; the closure is
            // merely typed non-isolated (and captures only Sendable
            // @MainActor models), so hop back with assumeIsolated — the same
            // pattern the window controller's monitors use.
            MainActor.assumeIsolated {
                let text = pickerModel?.isActive == true ? pickerModel?.filterText ?? "" : model.text
                openLayoutModel?.recordFieldHeight(height, fieldIsEmpty: text.isEmpty)
            }
        }
        .defaultFocus($fieldFocused, true)
        .onAppear {
            // Fresh field per open (matching the old @State behavior);
            // restore fills it only after a failed capture.
            model.text = restoreInput() ?? ""
            fieldFocused = true
            // Belt-and-braces for the hotkey path: if the panel gained key
            // status a beat after this view appeared, the request above was
            // dropped (fieldFocused reads back false). One bounded retry —
            // not polling — re-lands it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                if !staticRendering, !fieldFocused {
                    fieldFocused = true
                }
            }
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
        // Picker mode: Enter belongs to the key monitor (resume the selected
        // row) — it swallows the event before the field sees it. Belt and
        // braces for any path that still lands here (nothing to submit; the
        // filter text is not a capture).
        guard picker == nil else { return }
        let input = model.text
        model.text = "" // §5: the field clears after submit
        onSubmit(input)
    }
}

/// The capture field's rendered height, read from a GeometryReader in its
/// background and published into `OpenLayoutModel` (see CaptureView's
/// `onPreferenceChange`). One field, one value — `reduce` keeps the max
/// defensively, but only a single view ever sets this key.
private struct CaptureFieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
