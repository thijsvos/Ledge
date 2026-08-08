import Foundation

/// Paths into the repo-level fixtures directory (Tests/fixtures), resolved from
/// this source file's location so they work under both `swift test` and Xcode.
enum Fixtures {
    static var repoRoot: URL {
        // …/Sources/LedgeCore/Tests/LedgeCoreTests/TestSupport.swift → repo root is 4 levels up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var fixturesDir: URL {
        repoRoot.appendingPathComponent("Tests/fixtures")
    }

    static var vault: URL {
        fixturesDir.appendingPathComponent("vault")
    }

    static var fakeClaude: URL {
        fixturesDir.appendingPathComponent("fake-claude.sh")
    }
}
