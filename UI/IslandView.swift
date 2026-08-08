import LedgeCore
import SwiftUI

/// Shared motion constants (§4): exactly one spring everywhere, 80 ms hover
/// debounce.
enum IslandMotion {
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let hoverDebounce = Duration.milliseconds(80)
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
    /// ImageRenderer cannot rasterize AppKit-backed controls (TextField);
    /// --render-preview sets this to draw a static stand-in instead.
    var staticRendering: Bool

    @State private var captureText = ""
    @State private var statusDotDimmed = false
    @FocusState private var captureFieldFocused: Bool

    init(
        state: IslandState,
        layout: IslandLayout = .default,
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        onIslandTap: @escaping () -> Void = {},
        staticRendering: Bool = false
    ) {
        self.state = state
        self.layout = layout
        self.onHoverChanged = onHoverChanged
        self.onIslandTap = onIslandTap
        self.staticRendering = staticRendering
    }

    private static let capturePlaceholder = "Capture a thought — start with / for an agent run"

    /// The black shape's size for a state. Static so the window controller can
    /// hit-test click-outside against the same numbers.
    static func shapeSize(for state: IslandState, layout: IslandLayout) -> CGSize {
        switch state {
        case .collapsed, .running:
            layout.islandSize
        case .hover:
            // "Grown ~10 pt": 10 pt per side horizontally, 10 pt down.
            CGSize(width: layout.islandSize.width + 20, height: layout.islandSize.height + 10)
        case .open:
            CGSize(width: layout.windowSize.width, height: 120)
        case .peek:
            CGSize(width: layout.islandSize.width + 280, height: layout.islandSize.height + 44)
        }
    }

    private var shapeSize: CGSize {
        Self.shapeSize(for: state, layout: layout)
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
            .animation(IslandMotion.spring, value: state)
            .frame(
                width: layout.windowSize.width,
                height: layout.windowSize.height,
                alignment: .top
            )
            .onChange(of: state) { _, newState in
                captureFieldFocused = newState == .open
            }
            .onAppear {
                if state == .open {
                    captureFieldFocused = true
                }
            }
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
            // Capture field placeholder — Phase 2 wires InstantCapture and
            // AgentRun onto onSubmit; for now Enter does nothing.
            VStack(spacing: 0) {
                Spacer(minLength: layout.islandSize.height + 8) // clear of the physical notch
                if staticRendering {
                    // ImageRenderer cannot rasterize the AppKit-backed
                    // TextField; draw an equivalent static stand-in.
                    Text(Self.capturePlaceholder)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                } else {
                    TextField(Self.capturePlaceholder, text: $captureText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused($captureFieldFocused)
                        .onSubmit {} // Phase 2
                        .padding(.horizontal, 24)
                }
                Spacer()
            }
        case .running:
            // Animated status dot at the notch edge (only animates while a
            // run is live — nothing animates when idle).
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .opacity(statusDotDimmed ? 0.25 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.bottom, 5)
                .padding(.trailing, 10)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        statusDotDimmed = true
                    }
                }
                .onDisappear { statusDotDimmed = false }
        case let .peek(content):
            peekBody(content)
        }
    }

    private func peekBody(_ content: PeekContent) -> some View {
        HStack(spacing: 6) {
            switch content {
            case let .success(filesEdited, duration):
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                Text("\(filesEdited) file\(filesEdited == 1 ? "" : "s") · \(Int(duration.rounded()))s")
            case let .failure(message):
                Image(systemName: "xmark")
                    .foregroundStyle(.red)
                Text(message)
                    .lineLimit(1)
            case let .queued(position):
                Image(systemName: "clock")
                    .foregroundStyle(.yellow)
                Text("Queued #\(position)")
            case let .info(message):
                Text(message)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
        .padding(.horizontal, 16)
    }
}
