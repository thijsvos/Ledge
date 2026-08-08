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

    /// Copies the committed fixture vault into a fresh temp directory. Tests
    /// mutate the copy freely; the committed fixtures are NEVER touched.
    /// Callers remove the returned directory in tearDown.
    static func makeTempVaultCopy() throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: vault, to: destination)
        return destination
    }
}

/// Parses a strict ISO-8601 instant ("2026-08-07T23:59:59Z"). Test-only.
func utcDate(_ iso8601: String) -> Date {
    ISO8601DateFormatter().date(from: iso8601)!
}
