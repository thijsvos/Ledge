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

    static var liveProbe: URL {
        fixturesDir.appendingPathComponent("live-probe.ndjson")
    }

    /// A real final message from claude 2.1.226 answering the edit-plan
    /// contract: prose, then the plan in a fenced block. Captured so the
    /// extractor is pinned against what the CLI actually produces, not
    /// against what we imagine it produces.
    static var livePlanMessage: URL {
        fixturesDir.appendingPathComponent("live-plan-message.txt")
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
