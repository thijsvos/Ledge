// Notch geometry (§4 of the architecture doc). Pure value types and pure
// functions only — LedgeCore never imports AppKit; the App layer adapts
// NSScreen into `ScreenSnapshot`.

import CoreGraphics
import Foundation

/// A pure-value description of one display. All rects are in AppKit's
/// bottom-left-origin coordinate space (y grows upward), exactly as NSScreen
/// reports them.
public struct ScreenSnapshot: Equatable, Sendable {
    /// Full screen frame (`NSScreen.frame`).
    public var frame: CGRect
    /// Frame minus menu bar / Dock (`NSScreen.visibleFrame`).
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`; > 0 only on notched built-in displays.
    public var safeAreaTopInset: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` — the usable strip left of the notch.
    public var auxiliaryTopLeftArea: CGRect?
    /// `NSScreen.auxiliaryTopRightArea` — the usable strip right of the notch.
    public var auxiliaryTopRightArea: CGRect?

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: CGRect? = nil,
        auxiliaryTopRightArea: CGRect? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }
}

/// Whether the island sits in a real hardware notch or is a drawn fake island.
public enum IslandMode: String, Equatable, Sendable {
    case notch
    case fake
}

/// Everything the window layer needs for one screen, derived purely from a
/// `ScreenSnapshot`.
public struct IslandGeometry: Equatable, Sendable {
    public let mode: IslandMode
    /// The island (physical notch or fake island) in screen coordinates.
    public let islandRect: CGRect
    /// The constant expanded window frame in screen coordinates. The NSWindow
    /// is ALWAYS this size; only the shape inside animates (§4).
    public let windowFrame: CGRect

    public init(mode: IslandMode, islandRect: CGRect, windowFrame: CGRect) {
        self.mode = mode
        self.islandRect = islandRect
        self.windowFrame = windowFrame
    }
}

/// Pure geometry functions (§4). Unit-tested against hardcoded fixtures.
public enum NotchGeometry {
    /// Fake island width when the screen has no hardware notch.
    public static let fakeIslandWidth: CGFloat = 190
    /// Minimum fake island height (used when the menu bar is hidden/short).
    public static let fakeIslandMinHeight: CGFloat = 24
    /// The expanded window is the island width plus this much.
    public static let expandedExtraWidth: CGFloat = 560
    /// The expanded window height.
    public static let expandedHeight: CGFloat = 200

    /// A screen has a notch iff the top safe-area inset is positive AND both
    /// auxiliary top areas are present.
    ///
    /// Intentional (and pinned by
    /// `testSafeAreaWithoutAuxiliaryAreasFallsBackToFakeIsland`): §4 states the
    /// literal biconditional "notched ⇔ safeAreaInsets.top > 0", but §4's own
    /// notch-rect formula (`x = topLeft.maxX`, `width = frame.width −
    /// topLeft.width − topRight.width`) is uncomputable without both auxiliary
    /// areas, so a snapshot missing one must fall back to the fake island. On
    /// real hardware AppKit returns the auxiliary areas exactly when a camera
    /// housing exists, so behavior is identical. Do NOT "fix" this back to the
    /// bare safe-area check in a later phase.
    public static func hasNotch(_ screen: ScreenSnapshot) -> Bool {
        screen.safeAreaTopInset > 0
            && screen.auxiliaryTopLeftArea != nil
            && screen.auxiliaryTopRightArea != nil
    }

    /// The island rect in screen coordinates.
    ///
    /// Notched screen: `x = topLeft.maxX`,
    /// `width = frame.width − topLeft.width − topRight.width`,
    /// `height = safeAreaTopInset`, anchored to `frame.maxY`.
    ///
    /// No notch (MVP fallback): centered fake island, width 190 pt,
    /// height `max(frame.maxY − visibleFrame.maxY, 24)`.
    public static func islandRect(for screen: ScreenSnapshot) -> CGRect {
        if screen.safeAreaTopInset > 0,
           let topLeft = screen.auxiliaryTopLeftArea,
           let topRight = screen.auxiliaryTopRightArea
        {
            let width = screen.frame.width - topLeft.width - topRight.width
            return CGRect(
                x: topLeft.maxX,
                y: screen.frame.maxY - screen.safeAreaTopInset,
                width: width,
                height: screen.safeAreaTopInset
            )
        }
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, fakeIslandMinHeight)
        return CGRect(
            x: screen.frame.midX - fakeIslandWidth / 2,
            y: screen.frame.maxY - height,
            width: fakeIslandWidth,
            height: height
        )
    }

    /// The constant expanded window frame: island width + 560 pt wide,
    /// 200 pt tall, top-anchored to the screen, horizontally centered on the
    /// island. Not clamped to the screen — MVP islands are (near-)centered.
    public static func windowFrame(for screen: ScreenSnapshot) -> CGRect {
        let island = islandRect(for: screen)
        let width = island.width + expandedExtraWidth
        return CGRect(
            x: island.midX - width / 2,
            y: screen.frame.maxY - expandedHeight,
            width: width,
            height: expandedHeight
        )
    }

    /// Convenience bundle of everything derived from one snapshot.
    public static func geometry(for screen: ScreenSnapshot) -> IslandGeometry {
        IslandGeometry(
            mode: hasNotch(screen) ? .notch : .fake,
            islandRect: islandRect(for: screen),
            windowFrame: windowFrame(for: screen)
        )
    }
}
