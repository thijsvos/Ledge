@testable import LedgeCore
import XCTest

/// §6 escape hatch script: exact content, executable bit, quoting of
/// apostrophes in the vault path, and rejection of shell-metacharacter
/// session IDs.
final class ResumeScriptWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-resume-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testScriptContentIsExact() throws {
        let url = try ResumeScriptWriter.writeResumeScript(
            vaultPath: "/Users/test/vault",
            sessionID: "28c4ffe9-257b-472c-b034-2c3d3e638ca0",
            directory: directory
        )
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "cd '/Users/test/vault' && claude --resume '28c4ffe9-257b-472c-b034-2c3d3e638ca0'\n"
        )
    }

    func testScriptIsExecutableAndNamedForTerminal() throws {
        let url = try ResumeScriptWriter.writeResumeScript(
            vaultPath: "/Users/test/vault",
            sessionID: "abc-123",
            directory: directory
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("ledge-resume-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".command"))
    }

    /// Apostrophes in the vault path must be quoted with the '\'' idiom.
    func testApostropheInVaultPathIsEscaped() throws {
        let url = try ResumeScriptWriter.writeResumeScript(
            vaultPath: "/Users/test/thijs's vault",
            sessionID: "abc-123",
            directory: directory
        )
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "cd '/Users/test/thijs'\\''s vault' && claude --resume 'abc-123'\n"
        )
    }

    func testMaliciousSessionIDsAreRefused() {
        let malicious = [
            "abc'; rm -rf ~; echo '",
            "abc$(reboot)",
            "abc`id`",
            "abc def",
            "abc/../../etc",
            "",
            "café-1234",
        ]
        for sessionID in malicious {
            XCTAssertThrowsError(
                try ResumeScriptWriter.writeResumeScript(
                    vaultPath: "/Users/test/vault",
                    sessionID: sessionID,
                    directory: directory
                ),
                "must refuse session ID: \(sessionID)"
            ) { error in
                XCTAssertEqual(error as? ResumeScriptError, .invalidSessionID(sessionID))
            }
        }
    }

    /// "Copy command" shares the escaping logic; identical to the script body.
    func testCommandLineMatchesScriptBody() throws {
        XCTAssertEqual(
            try ResumeScriptWriter.commandLine(vaultPath: "/v", sessionID: "s-1"),
            "cd '/v' && claude --resume 's-1'"
        )
    }
}
