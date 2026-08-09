import LedgeCore
import SwiftUI

/// Shared motion constants (§4): exactly one spring everywhere, 80 ms hover
/// debounce. Reduced motion (§7) is implemented HERE and only here — no view
/// hand-rolls its own fallback.
enum IslandMotion {
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let hoverDebounce = Duration.milliseconds(80)
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

    @State private var statusDotDimmed = false

    init(
        state: IslandState,
        layout: IslandLayout = .default,
        reduceMotion: Bool = false,
        suggestionModel: SlashSuggestionModel? = nil,
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        onIslandTap: @escaping () -> Void = {},
        onSubmit: @escaping (String) -> Void = { _ in },
        captureRestoreInput: @escaping () -> String? = { nil },
        onOpenInTerminal: @escaping (ResumeAction) -> Void = { _ in },
        onCopyCommand: @escaping (ResumeAction) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {},
        staticRendering: Bool = false
    ) {
        self.state = state
        self.layout = layout
        self.reduceMotion = reduceMotion
        self.suggestionModel = suggestionModel
        self.onHoverChanged = onHoverChanged
        self.onIslandTap = onIslandTap
        self.onSubmit = onSubmit
        self.captureRestoreInput = captureRestoreInput
        self.onOpenInTerminal = onOpenInTerminal
        self.onCopyCommand = onCopyCommand
        self.onOpenSettings = onOpenSettings
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
    static func shapeSize(
        for state: IslandState, layout: IslandLayout, openSuggestionRows: Int = 0
    ) -> CGSize {
        switch state {
        case .collapsed, .running:
            return layout.islandSize
        case .hover:
            // "Grown ~10 pt": 10 pt per side horizontally, 10 pt down.
            return CGSize(width: layout.islandSize.width + 20, height: layout.islandSize.height + 10)
        case .open:
            let rows = CGFloat(min(max(openSuggestionRows, 0), SlashSuggestionModel.maxVisibleRows))
            return CGSize(
                width: layout.windowSize.width,
                height: min(120 + rows * SlashSuggestionList.rowHeight, layout.windowSize.height)
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

    /// Reading `visibleRowCount` in body makes SwiftUI re-render (and the
    /// shape re-size) as typing changes the match list.
    private var openSuggestionRows: Int {
        guard state == .open, !staticRendering, let suggestionModel else { return 0 }
        return suggestionModel.visibleRowCount
    }

    private var shapeSize: CGSize {
        Self.shapeSize(for: state, layout: layout, openSuggestionRows: openSuggestionRows)
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
            // The open shape growing/shrinking with the suggestion list uses
            // the same one spring (or reduced-motion fade) as state changes.
            .animation(IslandMotion.animation(reduceMotion: reduceMotion), value: openSuggestionRows)
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
                suggestionModel: suggestionModel
            )
        case .running:
            // Animated status dot at the notch edge (only animates while a
            // run is live — nothing animates when idle). Reduced motion (§7):
            // the dot stays solid instead of pulsing — enforced reactively
            // (`onChange`), so flipping the setting WHILE a run is live stops
            // or starts the pulse immediately, not just on first appearance.
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .opacity(statusDotDimmed ? 0.25 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.bottom, 5)
                .padding(.trailing, 10)
                .onAppear { updateStatusDotPulse() }
                .onChange(of: reduceMotion) { updateStatusDotPulse() }
                .onDisappear { statusDotDimmed = false }
        case let .peek(content):
            PeekView(
                content: content,
                onOpenInTerminal: onOpenInTerminal,
                onCopyCommand: onCopyCommand,
                onOpenSettings: onOpenSettings
            )
        }
    }

    /// Starts the pulse (IslandMotion.statusDotPulse) or cancels it: setting
    /// the value inside `withAnimation(nil)` retargets the opacity without an
    /// animation, which supersedes an in-flight `repeatForever` — the dot
    /// snaps solid the moment Reduce Motion turns on.
    private func updateStatusDotPulse() {
        if reduceMotion {
            withAnimation(nil) { statusDotDimmed = false }
        } else {
            withAnimation(IslandMotion.statusDotPulse) { statusDotDimmed = true }
        }
    }
}
