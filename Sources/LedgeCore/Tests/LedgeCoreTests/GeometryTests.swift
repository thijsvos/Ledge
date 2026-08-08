@testable import LedgeCore
import XCTest

/// §4 geometry against four hardcoded fixtures (all rects in AppKit
/// bottom-left coordinate space).
final class GeometryTests: XCTestCase {
    // MARK: - Fixtures

    /// 14" MacBook Pro: 1512×982, safe-area top 32, notch 200 pt wide.
    static let mbp14 = ScreenSnapshot(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTopInset: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
        auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32)
    )

    /// 16" MacBook Pro: 1728×1117, safe-area top 37, notch 200 pt wide.
    static let mbp16 = ScreenSnapshot(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
        safeAreaTopInset: 37,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 1080, width: 764, height: 37),
        auxiliaryTopRightArea: CGRect(x: 964, y: 1080, width: 764, height: 37)
    )

    /// 13" MacBook Air: 1280×832, safe-area top 32, notch 200 pt wide.
    static let air13 = ScreenSnapshot(
        frame: CGRect(x: 0, y: 0, width: 1280, height: 832),
        visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
        safeAreaTopInset: 32,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 800, width: 540, height: 32),
        auxiliaryTopRightArea: CGRect(x: 740, y: 800, width: 540, height: 32)
    )

    /// No-notch external display: 1920×1080, 24 pt menu bar, no aux areas.
    static let external = ScreenSnapshot(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056),
        safeAreaTopInset: 0,
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil
    )

    // MARK: - 14" MBP

    func testMBP14HasNotch() {
        XCTAssertTrue(NotchGeometry.hasNotch(Self.mbp14))
        XCTAssertEqual(NotchGeometry.geometry(for: Self.mbp14).mode, .notch)
    }

    func testMBP14NotchRect() {
        XCTAssertEqual(
            NotchGeometry.islandRect(for: Self.mbp14),
            CGRect(x: 656, y: 950, width: 200, height: 32)
        )
    }

    func testMBP14WindowFrame() {
        XCTAssertEqual(
            NotchGeometry.windowFrame(for: Self.mbp14),
            CGRect(x: 376, y: 782, width: 760, height: 200)
        )
    }

    // MARK: - 16" MBP

    func testMBP16HasNotch() {
        XCTAssertTrue(NotchGeometry.hasNotch(Self.mbp16))
        XCTAssertEqual(NotchGeometry.geometry(for: Self.mbp16).mode, .notch)
    }

    func testMBP16NotchRect() {
        XCTAssertEqual(
            NotchGeometry.islandRect(for: Self.mbp16),
            CGRect(x: 764, y: 1080, width: 200, height: 37)
        )
    }

    func testMBP16WindowFrame() {
        XCTAssertEqual(
            NotchGeometry.windowFrame(for: Self.mbp16),
            CGRect(x: 484, y: 917, width: 760, height: 200)
        )
    }

    // MARK: - 13" Air

    func testAir13HasNotch() {
        XCTAssertTrue(NotchGeometry.hasNotch(Self.air13))
        XCTAssertEqual(NotchGeometry.geometry(for: Self.air13).mode, .notch)
    }

    func testAir13NotchRect() {
        XCTAssertEqual(
            NotchGeometry.islandRect(for: Self.air13),
            CGRect(x: 540, y: 800, width: 200, height: 32)
        )
    }

    func testAir13WindowFrame() {
        XCTAssertEqual(
            NotchGeometry.windowFrame(for: Self.air13),
            CGRect(x: 260, y: 632, width: 760, height: 200)
        )
    }

    // MARK: - No-notch external

    func testExternalHasNoNotch() {
        XCTAssertFalse(NotchGeometry.hasNotch(Self.external))
        XCTAssertEqual(NotchGeometry.geometry(for: Self.external).mode, .fake)
    }

    func testExternalFakeIslandRect() {
        // Centered, width 190, height max(1080 − 1056, 24) = 24.
        XCTAssertEqual(
            NotchGeometry.islandRect(for: Self.external),
            CGRect(x: 865, y: 1056, width: 190, height: 24)
        )
    }

    func testExternalWindowFrame() {
        XCTAssertEqual(
            NotchGeometry.windowFrame(for: Self.external),
            CGRect(x: 585, y: 880, width: 750, height: 200)
        )
    }

    // MARK: - Edge cases

    /// hasNotch requires BOTH aux areas: a positive safe-area inset alone
    /// falls back to the fake island.
    func testSafeAreaWithoutAuxiliaryAreasFallsBackToFakeIsland() {
        var snapshot = Self.mbp14
        snapshot.auxiliaryTopRightArea = nil
        XCTAssertFalse(NotchGeometry.hasNotch(snapshot))
        XCTAssertEqual(NotchGeometry.geometry(for: snapshot).mode, .fake)
        XCTAssertEqual(NotchGeometry.islandRect(for: snapshot).width, 190)
    }

    /// Menu bar hidden (visibleFrame.maxY == frame.maxY) → fake island floor
    /// of 24 pt.
    func testFakeIslandMinimumHeightWhenMenuBarHidden() {
        let snapshot = ScreenSnapshot(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTopInset: 0
        )
        XCTAssertEqual(
            NotchGeometry.islandRect(for: snapshot),
            CGRect(x: 865, y: 1056, width: 190, height: 24)
        )
    }

    /// A non-zero-origin screen (secondary display arrangement) keeps rects in
    /// that screen's global coordinates.
    func testNonZeroOriginScreen() {
        let snapshot = ScreenSnapshot(
            frame: CGRect(x: 1512, y: 100, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 100, width: 1920, height: 1056),
            safeAreaTopInset: 0
        )
        XCTAssertEqual(
            NotchGeometry.islandRect(for: snapshot),
            CGRect(x: 1512 + 865, y: 1156, width: 190, height: 24)
        )
        XCTAssertEqual(
            NotchGeometry.windowFrame(for: snapshot),
            CGRect(x: 1512 + 585, y: 980, width: 750, height: 200)
        )
    }
}
