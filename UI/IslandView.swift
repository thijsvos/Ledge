import LedgeCore
import SwiftUI

/// Shared motion constants (§4): exactly one spring everywhere, 55 ms hover
/// debounce. Reduced motion (§7) is implemented HERE and only here — no view
/// hand-rolls its own fallback.
///
/// Tuned during human QA (2026-08-17). The state machine was never the cost —
/// a transition's synchronous body measures 0.02–0.15 ms — so "not quite
/// instant" was entirely these two numbers: a spring response of 0.32 s, and a
/// debounce during which nothing moves at all. Both came down; the spring's
/// damping went up slightly to keep a shorter response from reading as bouncy.
enum IslandMotion {
    static let spring = Animation.spring(response: 0.18, dampingFraction: 0.85)
    /// The dead period before a hover is believed. Long enough that a pointer
    /// crossing the notch on its way elsewhere does not make the island twitch,
    /// short enough that a deliberate hover feels answered.
    static let hoverDebounce = Duration.milliseconds(40)
    /// ~150 ms cross-fade used for every state change when the system's
    /// reduce-motion accessibility setting is on — no spring overshoot.
    static let reducedMotionFade = Animation.easeInOut(duration: 0.15)
    /// Status-dot pulse while a run is live (§4 `.running`). Lives here with
    /// every other animation; IslandView drives it reactively so a LIVE
    /// Reduce Motion change stops or starts the pulse immediately.
    static let statusDotPulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)

    /// The one animation every island state change uses. `reduceMotion` comes
    /// from NSWorkspace (observed by the App layer) — behavior with
    /// `reduceMotion == false` is EXACTLY the Phase-1 spring.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotionFade : spring
    }
}

/// The sizes the island view lays out against, derived from `IslandGeometry`.
/// `windowSize` is the constant expanded window; `islandSize` is the physical
/// notch (or fake island) the collapsed shape must match pixel-for-pixel.
struct IslandLayout: Equatable, Sendable {
    var islandSize: CGSize
    var windowSize: CGSize

    /// 14" MBP-shaped default so `IslandView(state:)` is constructible from a
    /// bare `IslandState` (required by --render-preview).
    static let `default` = IslandLayout(
        islandSize: CGSize(width: 200, height: 32),
        windowSize: CGSize(width: 760, height: 200)
    )

    init(islandSize: CGSize, windowSize: CGSize) {
        self.islandSize = islandSize
        self.windowSize = windowSize
    }

    init(geometry: IslandGeometry) {
        self.init(islandSize: geometry.islandRect.size, windowSize: geometry.windowFrame.size)
    }
}

/// The whole island, rendered inside the constant expanded window frame. The
/// black shape animates between per-state sizes; the NSWindow never resizes
/// (§4).
struct IslandView: View {
    var state: IslandState
    var layout: IslandLayout
    var onHoverChanged: (Bool) -> Void
    var onIslandTap: () -> Void
    /// Enter in the capture field: raw input for CaptureCoordinator. Defaulted
    /// so `IslandView(state:)` stays constructible with no coordinator
    /// (--render-preview uses a static stand-in anyway).
    var onSubmit: (String) -> Void
    /// Non-nil when the capture field should refill with preserved input (a
    /// failed capture's text — see CaptureCoordinator). Defaulted so
    /// `IslandView(state:)` stays constructible with no coordinator.
    var captureRestoreInput: () -> String?
    /// §6 escape hatch handlers for failure peeks (App layer: script + open /
    /// pasteboard). Defaulted so `IslandView(state:)` stays constructible.
    var onOpenInTerminal: (ResumeAction) -> Void
    var onCopyCommand: (ResumeAction) -> Void
    /// §7: configuration-failure peeks offer "Open Settings…".
    var onOpenSettings: () -> Void
    /// §7 reduced motion (from NSWorkspace, observed by the App layer): every
    /// state change becomes IslandMotion's ~150 ms fade instead of the spring.
    /// Defaults to false — --render-preview stays static and unaffected.
    var reduceMotion: Bool
    /// ImageRenderer cannot rasterize AppKit-backed controls (TextField);
    /// --render-preview sets this to draw a static stand-in instead.
    var staticRendering: Bool
    /// The slash-command typeahead model (owned by the window controller).
    /// Nil — the default, and what --render-preview's bare `IslandView(state:)`
    /// gets — means no suggestions ever: the open shape stays its Phase-1
    /// 120 pt and CaptureView falls back to an inert model.
    var suggestionModel: SlashSuggestionModel?
    /// The /resume picker model (owned by the window controller). Nil — the
    /// default, and what --render-preview gets — means picker mode never
    /// renders; previews are unchanged.
    var pickerModel: ResumePickerModel?
    /// The ⌘↩ per-run model chooser (owned by the window controller). Nil —
    /// the default, and what --render-preview gets — means chooser mode
    /// never renders; previews are unchanged.
    var modelChoiceModel: ModelChoiceModel?
    /// Live-run status (owned by the window controller; AgentRunController
    /// writes the run bookkeeping, the hover machinery writes the hover
    /// flag). Nil — the default, and what --render-preview's bare
    /// `IslandView(state:)` gets — means the running dot never widens into
    /// the status chip; previews are unchanged (no run exists in a static
    /// preview anyway).
    var runStatusModel: RunStatusModel?
    /// The capture field's measured wrap growth (owned by the window
    /// controller; CaptureView publishes into it). Nil — the default, and
    /// what --render-preview gets — means the open shape never grows with
    /// the field; previews are unchanged.
    var openLayoutModel: OpenLayoutModel?
    /// Picker row click → resume that session (App layer).
    var onPickerSelect: (RunRecord) -> Void
    /// Chooser row click → submit the current field text with that per-run
    /// model choice (App layer).
    var onModelChoiceSelect: (RunModelChoice) -> Void

    init(
        state: IslandState,
        layout: IslandLayout = .default,
        reduceMotion: Bool = false,
        suggestionModel: SlashSuggestionModel? = nil,
        pickerModel: ResumePickerModel? = nil,
        modelChoiceModel: ModelChoiceModel? = nil,
        openLayoutModel: OpenLayoutModel? = nil,
        runStatusModel: RunStatusModel? = nil,
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        onIslandTap: @escaping () -> Void = {},
        onSubmit: @escaping (String) -> Void = { _ in },
        captureRestoreInput: @escaping () -> String? = { nil },
        onOpenInTerminal: @escaping (ResumeAction) -> Void = { _ in },
        onCopyCommand: @escaping (ResumeAction) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {},
        onPickerSelect: @escaping (RunRecord) -> Void = { _ in },
        onModelChoiceSelect: @escaping (RunModelChoice) -> Void = { _ in },
        staticRendering: Bool = false
    ) {
        self.state = state
        self.layout = layout
        self.reduceMotion = reduceMotion
        self.suggestionModel = suggestionModel
        self.pickerModel = pickerModel
        self.modelChoiceModel = modelChoiceModel
        self.openLayoutModel = openLayoutModel
        self.runStatusModel = runStatusModel
        self.onHoverChanged = onHoverChanged
        self.onIslandTap = onIslandTap
        self.onSubmit = onSubmit
        self.captureRestoreInput = captureRestoreInput
        self.onOpenInTerminal = onOpenInTerminal
        self.onCopyCommand = onCopyCommand
        self.onOpenSettings = onOpenSettings
        self.onPickerSelect = onPickerSelect
        self.onModelChoiceSelect = onModelChoiceSelect
        self.staticRendering = staticRendering
    }

    /// The black shape's size for a state. Static so the window controller can
    /// hit-test click-outside against the same numbers.
    ///
    /// `openSuggestionRows` (only meaningful for `.open`) is how many
    /// suggestion rows the list shows (≤ `SlashSuggestionModel.maxVisibleRows`
    /// = 4): the 120 pt base grows by one 22 pt row height each, capped at
    /// the constant 200 pt window height — 0 → 120, 1 → 142, 2 → 164,
    /// 3 → 186, 4 → 200 (capped from 208). The 4-row cap is the CONTENT
    /// budget: CaptureView's chrome above the list (notch clearance + field
    /// row + hint + stack gaps) plus 5 fixed-height rows would need ≥ 205 pt
    /// inside the 200 pt window and clip the bottom row — see
    /// `SlashSuggestionModel.maxVisibleRows`.
    ///
    /// `openChooserRows` (only meaningful for `.open`) is the ⌘↩ per-run
    /// model chooser's row count (3 while active, 0 otherwise). The chooser
    /// replaces the suggestion list (same base height, same 22 pt rows) and
    /// wins over it; the /resume picker still wins over both — see `openPlan`.
    ///
    /// `openFieldExtraHeight` (only meaningful for `.open`) is the capture
    /// field's measured wrap growth (`OpenLayoutModel.fieldExtraHeight`); it
    /// grows the shape the same way and WINS the row budget — see `openPlan`.
    ///
    /// `runningHoverStatus` (only meaningful for `.running`) is
    /// `RunStatusModel.isHoveringWhileRunning`: the dot widens into the
    /// status chip ("● M:SS · <prompt excerpt>"). Both consumers — the drawn
    /// shape and the click-outside hit-test — must pass the value from the
    /// SAME RunStatusModel instance.
    static func shapeSize(
        for state: IslandState, layout: IslandLayout, openSuggestionRows: Int = 0,
        openPickerRows: Int = 0, openChooserRows: Int = 0, openFieldExtraHeight: CGFloat = 0,
        runningHoverStatus: Bool = false
    ) -> CGSize {
        switch state {
        case .running where runningHoverStatus:
            // The hover status chip: wide enough for "● M:SS · " plus the
            // ~44-character prompt excerpt at the chip's 11 pt font (half on
            // each side of the collapsed island), and a peek-style strip
            // taller — in notch mode `islandSize` IS the hardware cutout, so
            // the chip's text row must live BELOW it (bottom-anchored, like
            // every peek), never centered inside the occluded band.
            return CGSize(
                width: layout.islandSize.width + runningStatusChipExtraWidth,
                height: layout.islandSize.height + runningStatusChipExtraHeight
            )
        case .collapsed, .running:
            return layout.islandSize
        case .hover:
            // "Grown ~10 pt": 10 pt per side horizontally, 10 pt down.
            return CGSize(width: layout.islandSize.width + 20, height: layout.islandSize.height + 10)
        case .open:
            return CGSize(
                width: layout.windowSize.width,
                height: openPlan(
                    layout: layout,
                    openSuggestionRows: openSuggestionRows,
                    openPickerRows: openPickerRows,
                    openChooserRows: openChooserRows,
                    openFieldExtraHeight: openFieldExtraHeight
                ).height
            )
        case let .peek(content):
            // Failure peeks grow with their message (§6: headline + up to 3
            // stderr-tail lines) and carry a button row when resumable (§6
            // escape hatch) or when configuration guidance offers Settings.
            if case let .failure(message, resume, configuration) = content {
                let hasButtons = resume != nil || configuration
                let lines = min(
                    message.split(separator: "\n", omittingEmptySubsequences: false).count, 4
                )
                let buttonRow: CGFloat = hasButtons ? 30 : 0
                return CGSize(
                    width: layout.islandSize.width + (hasButtons ? 340 : 280),
                    height: layout.islandSize.height + 28 + CGFloat(lines) * 16 + buttonRow
                )
            }
            return CGSize(
                width: layout.islandSize.width + 280,
                height: layout.islandSize.height + 44
            )
        }
    }

    /// How much wider the island grows when the running dot is hovered into
    /// the status chip (+220 pt total, split evenly by the top-centered
    /// layout). A constant, like `.hover`'s +20: the chip shows one fixed
    /// line — "● M:SS · <prompt excerpt>" — whose excerpt is already capped
    /// at ~44 characters (`RunStatusModel.excerpt`), so nothing about the
    /// live prompt may change the shape's size mid-hover.
    static let runningStatusChipExtraWidth: CGFloat = 220

    /// How much taller the chip is than the collapsed island: a peek-style
    /// strip below the island for the chip's one text row. In notch mode the
    /// collapsed island is exactly the hardware cutout — content drawn inside
    /// that band has no pixels (the camera housing occludes it) — so the row
    /// bottom-anchors into this strip, the same discipline as PeekView and
    /// the hover chevron. 28 pt fits the 13 pt row plus PeekView's 8 pt
    /// bottom padding with breathing room.
    static let runningStatusChipExtraHeight: CGFloat = 28

    /// The `.open` shape's height AND the list-row budget that fits inside
    /// it, from one `OpenIslandLayout.compute` call (LedgeCore-tested math) —
    /// ONE function so the drawn shape, the rows CaptureView actually
    /// renders, and the controller's click-outside hit-test can never
    /// disagree. The field wins the budget: a wrap-grown field shrinks the
    /// row budget (to 0 if needed — worst case the list hides) rather than
    /// ever being clipped; with a one-line field (`openFieldExtraHeight` 0)
    /// the results are byte-identical to the pre-wrap formulas.
    ///
    /// Picker mode wins (mirrors CaptureView's rendering precedence). Its
    /// base is 90 pt, not 120: the hint line is hidden in picker mode, which
    /// is exactly what lets 5 × 22 pt rows fit inside the constant 200 pt
    /// window (90 + 5 × 22 = 200; the suggestion list's 120 pt base fits
    /// only 4).
    ///
    /// The ⌘↩ model chooser comes next: it replaces the suggestion list
    /// (hint line still shown, so the suggestion list's 120 pt base and
    /// 22 pt rows apply — 120 + 3 × 22 = 186 fits comfortably) and wins over
    /// it while active.
    static func openPlan(
        layout: IslandLayout, openSuggestionRows: Int, openPickerRows: Int,
        openChooserRows: Int, openFieldExtraHeight: CGFloat
    ) -> (height: CGFloat, rowBudget: Int) {
        let plan = if openPickerRows > 0 {
            OpenIslandLayout.compute(
                fieldExtraHeight: openFieldExtraHeight,
                requestedRows: min(openPickerRows, ResumePickerModel.maxVisibleRows),
                rowHeight: ResumePickerList.rowHeight,
                baseHeight: 90,
                maxHeight: layout.windowSize.height
            )
        } else if openChooserRows > 0 {
            OpenIslandLayout.compute(
                fieldExtraHeight: openFieldExtraHeight,
                requestedRows: min(openChooserRows, ModelChoiceModel.maxVisibleRows),
                rowHeight: ModelChoiceList.rowHeight,
                baseHeight: 120,
                maxHeight: layout.windowSize.height
            )
        } else {
            OpenIslandLayout.compute(
                fieldExtraHeight: openFieldExtraHeight,
                requestedRows: min(max(openSuggestionRows, 0), SlashSuggestionModel.maxVisibleRows),
                rowHeight: SlashSuggestionList.rowHeight,
                baseHeight: 120,
                maxHeight: layout.windowSize.height
            )
        }
        return (plan.shapeHeight, plan.visibleRows)
    }

    /// Reading `visibleRowCount` in body makes SwiftUI re-render (and the
    /// shape re-size) as typing changes the match list.
    private var openSuggestionRows: Int {
        guard state == .open, !staticRendering, let suggestionModel else { return 0 }
        return suggestionModel.visibleRowCount
    }

    /// > 0 exactly while the /resume picker is active (then at least 1 — the
    /// "No matching sessions" row keeps one row of height under an
    /// over-narrow filter).
    private var openPickerRows: Int {
        guard state == .open, !staticRendering, let pickerModel, pickerModel.isActive
        else { return 0 }
        return max(1, pickerModel.visibleRowCount)
    }

    /// > 0 exactly while the ⌘↩ model chooser is active (its 3 fixed rows).
    /// Reading `visibleRowCount` in body makes SwiftUI re-render (and the
    /// shape re-size) when the chooser activates or deactivates.
    private var openChooserRows: Int {
        guard state == .open, !staticRendering, let modelChoiceModel, modelChoiceModel.isActive
        else { return 0 }
        return modelChoiceModel.visibleRowCount
    }

    /// The capture field's measured wrap growth — 0 when not open, in static
    /// previews, or without a layout model (--render-preview's bare
    /// `IslandView(state:)`). Reading it in body makes SwiftUI re-render (and
    /// the shape re-size) as typing wraps or unwraps the field.
    private var openFieldExtra: CGFloat {
        guard state == .open, !staticRendering, let openLayoutModel else { return 0 }
        return openLayoutModel.fieldExtraHeight
    }

    /// True while the running dot should render as the hover status chip.
    /// Reading `isHoveringWhileRunning` in body makes SwiftUI re-render (and
    /// the shape re-size) when the hover machinery flips it. False when not
    /// `.running`, in static previews, or without a model (--render-preview's
    /// bare `IslandView(state:)`).
    private var runningHoverStatus: Bool {
        guard case .running = state, !staticRendering, let runStatusModel else { return false }
        return runStatusModel.isHoveringWhileRunning
    }

    private var shapeSize: CGSize {
        Self.shapeSize(
            for: state,
            layout: layout,
            openSuggestionRows: openSuggestionRows,
            openPickerRows: openPickerRows,
            openChooserRows: openChooserRows,
            openFieldExtraHeight: openFieldExtra,
            runningHoverStatus: runningHoverStatus
        )
    }

    private var bottomRadius: CGFloat {
        switch state {
        case .collapsed, .running: 8
        case .hover: 10
        case .peek: 12
        case .open: 16
        }
    }

    var body: some View {
        NotchShape(bottomRadius: bottomRadius)
            .fill(Color.black)
            .frame(width: shapeSize.width, height: shapeSize.height)
            .overlay { stateContent }
            // Hit-testing is limited to the black shape so clicks beside it
            // fall through to whatever is behind the window. §4 documented
            // fallback if pass-through proves unreliable in Phase 1 QA:
            // shrink the window frame in the collapsed state instead.
            .contentShape(NotchShape(bottomRadius: bottomRadius))
            .onHover(perform: onHoverChanged)
            .onTapGesture(perform: onIslandTap)
            .animation(IslandMotion.animation(reduceMotion: reduceMotion), value: state)
            // The open shape growing/shrinking with the suggestion list (or
            // the /resume picker) uses the same one spring (or reduced-motion
            // fade) as state changes.
            .animation(IslandMotion.animation(reduceMotion: reduceMotion), value: openSuggestionRows)
            .animation(IslandMotion.animation(reduceMotion: reduceMotion), value: openPickerRows)
            // …and the ⌘↩ model chooser appearing/disappearing: same spring.
            .animation(IslandMotion.animation(reduceMotion: reduceMotion), value: openChooserRows)
            // …and the shape growing/shrinking as the capture field wraps
            // onto more or fewer lines uses that same one animation too.
            .animation(IslandMotion.animation(reduceMotion: reduceMotion), value: openFieldExtra)
            // …and the running dot widening into (or out of) the hover
            // status chip: the same one spring, reduced motion = fade.
            .animation(IslandMotion.animation(reduceMotion: reduceMotion), value: runningHoverStatus)
            .frame(
                width: layout.windowSize.width,
                height: layout.windowSize.height,
                alignment: .top
            )
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .collapsed:
            EmptyView()
        case .hover:
            // Affordance hint: a faint chevron at the bottom edge.
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 3)
        case .open:
            // The §5 capture UI: field + "/" hint + live target chip.
            CaptureView(
                topClearance: layout.islandSize.height + 8, // clear of the physical notch
                staticRendering: staticRendering,
                onSubmit: onSubmit,
                restoreInput: captureRestoreInput,
                suggestionModel: suggestionModel,
                pickerModel: pickerModel,
                modelChoiceModel: modelChoiceModel,
                onPickerSelect: onPickerSelect,
                onModelChoiceSelect: onModelChoiceSelect,
                openLayoutModel: openLayoutModel,
                // The SAME openPlan the shape is drawn from: rows the grown
                // field's budget no longer covers are not rendered, so the
                // list can never paint below the black shape.
                listRowLimit: Self.openPlan(
                    layout: layout,
                    openSuggestionRows: openSuggestionRows,
                    openPickerRows: openPickerRows,
                    openChooserRows: openChooserRows,
                    openFieldExtraHeight: openFieldExtra
                ).rowBudget
            )
        case .running:
            // Animated status dot at the notch edge (only animates while a
            // run is live — nothing animates when idle). Hovering the dot
            // widens the island into the status chip: elapsed time + prompt
            // excerpt, from the shared RunStatusModel. The TimelineView
            // ticking the elapsed label is mounted ONLY inside the chip —
            // zero timers when not hovering (§10; an active run with the
            // pointer parked on the island is not idle).
            if runningHoverStatus {
                runningStatusChip
            } else {
                PulsingStatusDot(reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, 5)
                    .padding(.trailing, 10)
            }
        case let .peek(content):
            PeekView(
                content: content,
                onOpenInTerminal: onOpenInTerminal,
                onCopyCommand: onCopyCommand,
                onOpenSettings: onOpenSettings
            )
        }
    }

    /// The hover status chip's content: the same pulsing dot plus
    /// "M:SS · <prompt excerpt>" (monospaced digits, single line). The
    /// elapsed label re-renders once per second via TimelineView's periodic
    /// schedule anchored at the run's start date — no Timer, and the
    /// schedule exists only while this chip is on screen. A nil start date
    /// (the sub-second gap between a completion and the next queued run's
    /// runStarted) renders the excerpt alone rather than a bogus clock.
    ///
    /// Bottom-anchored like PeekView's content: the row must sit in the
    /// `runningStatusChipExtraHeight` strip BELOW the collapsed island —
    /// in notch mode the island band is the physical cutout and anything
    /// centered inside it would be occluded by the camera housing.
    private var runningStatusChip: some View {
        HStack(spacing: 6) {
            PulsingStatusDot(reduceMotion: reduceMotion)
            if let start = runStatusModel?.runStartDate {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(
                        "\(Self.elapsedLabel(from: start, to: context.date)) · \(runStatusModel?.promptExcerpt ?? "")"
                    )
                }
            } else {
                Text(runStatusModel?.promptExcerpt ?? "")
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
        .padding(.horizontal, 14)
    }

    /// "M:SS" elapsed wall-clock label (0:07, 1:42, 13:05 — minutes unpadded,
    /// seconds always two digits); never negative.
    static func elapsedLabel(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// The §4 running-dot pulse, self-contained so the plain dot and the hover
/// chip each own an independent pulse lifecycle (branch switches then never
/// race onAppear/onDisappear over shared state). Reduced motion (§7): the
/// dot stays solid instead of pulsing — enforced reactively (`onChange`), so
/// flipping the setting WHILE a run is live stops or starts the pulse
/// immediately, not just on first appearance.
private struct PulsingStatusDot: View {
    var reduceMotion: Bool
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .opacity(dimmed ? 0.25 : 1)
            .onAppear { updatePulse() }
            .onChange(of: reduceMotion) { updatePulse() }
    }

    /// Starts the pulse (IslandMotion.statusDotPulse) or cancels it: setting
    /// the value inside `withAnimation(nil)` retargets the opacity without an
    /// animation, which supersedes an in-flight `repeatForever` — the dot
    /// snaps solid the moment Reduce Motion turns on.
    private func updatePulse() {
        if reduceMotion {
            withAnimation(nil) { dimmed = false }
        } else {
            withAnimation(IslandMotion.statusDotPulse) { dimmed = true }
        }
    }
}
