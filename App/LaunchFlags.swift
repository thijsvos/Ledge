import AppKit
import ImageIO
import LedgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Launch flags handled in `main()` BEFORE `NSApplication.run` (§9 Phase 1).
/// The process exits with the returned code; the app never starts.
@MainActor
enum LaunchFlags {
    /// Returns an exit code when a flag was handled, or nil to continue into
    /// the normal app lifecycle.
    static func handle(_ arguments: [String]) -> Int32? {
        switch arguments.first {
        case "--dump-geometry":
            dumpGeometry()
        case "--render-preview":
            renderPreview(Array(arguments.dropFirst()))
        default:
            nil
        }
    }

    // MARK: - --dump-geometry

    private struct RectDTO: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }
    }

    private struct InputsDTO: Codable {
        var frame: RectDTO
        var visibleFrame: RectDTO
        var safeAreaTopInset: Double
        var auxiliaryTopLeftArea: RectDTO?
        var auxiliaryTopRightArea: RectDTO?

        init(_ snapshot: ScreenSnapshot) {
            frame = RectDTO(snapshot.frame)
            visibleFrame = RectDTO(snapshot.visibleFrame)
            safeAreaTopInset = snapshot.safeAreaTopInset
            auxiliaryTopLeftArea = snapshot.auxiliaryTopLeftArea.map(RectDTO.init)
            auxiliaryTopRightArea = snapshot.auxiliaryTopRightArea.map(RectDTO.init)
        }

        /// Explicit nulls (instead of omitted keys) so the document shape is
        /// identical for notch and fake screens.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(frame, forKey: .frame)
            try container.encode(visibleFrame, forKey: .visibleFrame)
            try container.encode(safeAreaTopInset, forKey: .safeAreaTopInset)
            try container.encode(auxiliaryTopLeftArea, forKey: .auxiliaryTopLeftArea)
            try container.encode(auxiliaryTopRightArea, forKey: .auxiliaryTopRightArea)
        }
    }

    private struct ScreenDTO: Codable {
        var mode: String
        var island: RectDTO
        var windowFrame: RectDTO
        var inputs: InputsDTO
    }

    private struct DumpDTO: Codable {
        var screens: [ScreenDTO]
    }

    /// One valid JSON document on stdout describing every screen.
    private static func dumpGeometry() -> Int32 {
        let screens = NSScreen.screens.map { screen in
            let snapshot = ScreenSnapshot(screen: screen)
            let geometry = NotchGeometry.geometry(for: snapshot)
            return ScreenDTO(
                mode: geometry.mode.rawValue,
                island: RectDTO(geometry.islandRect),
                windowFrame: RectDTO(geometry.windowFrame),
                inputs: InputsDTO(snapshot)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(DumpDTO(screens: screens))
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch {
            printError("--dump-geometry failed to encode: \(error)")
            return 1
        }
    }

    // MARK: - --render-preview

    /// `--render-preview <collapsed|hover|open> <out.png>`: renders IslandView
    /// for that state offscreen via ImageRenderer at the expanded window size.
    private static func renderPreview(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2 else {
            printError("usage: --render-preview <collapsed|hover|open> <out.png>")
            return 1
        }

        let state: IslandState
        switch arguments[0] {
        case "collapsed": state = .collapsed
        case "hover": state = .hover
        case "open": state = .open
        default:
            printError("unknown state '\(arguments[0])' (expected collapsed, hover, or open)")
            return 1
        }

        let layout: IslandLayout = if let main = NSScreen.main {
            IslandLayout(geometry: NotchGeometry.geometry(for: ScreenSnapshot(screen: main)))
        } else {
            .default
        }

        let renderer = ImageRenderer(
            content: IslandView(state: state, layout: layout, staticRendering: true)
        )
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            printError("--render-preview: ImageRenderer produced no image")
            return 1
        }

        let url = URL(fileURLWithPath: arguments[1])
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            printError("--render-preview: cannot create \(url.path)")
            return 1
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            printError("--render-preview: failed writing \(url.path)")
            return 1
        }
        return 0
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
