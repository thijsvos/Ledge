@testable import LedgeCore
import XCTest

/// Vault validation and helpers (§5). Mutating tests run against a fresh temp
/// copy of the fixture vault; the committed fixtures are never touched.
final class VaultTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = try Fixtures.makeTempVaultCopy()
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    private func tempVault() throws -> Vault {
        try Vault(root: tempRoot)
    }

    // MARK: - Validation

    func testInitSucceedsOnExistingDirectory() throws {
        let vault = try Vault(root: Fixtures.vault)
        XCTAssertEqual(vault.root, Fixtures.vault)
    }

    func testInitThrowsWhenPathDoesNotExist() {
        let missing = Fixtures.vault.appendingPathComponent("no-such-dir")
        XCTAssertThrowsError(try Vault(root: missing)) { error in
            XCTAssertEqual(error as? VaultError, .rootDoesNotExist(path: missing.path))
        }
    }

    func testInitThrowsWhenPathIsAFile() {
        let file = Fixtures.vault.appendingPathComponent("CLAUDE.md")
        XCTAssertThrowsError(try Vault(root: file)) { error in
            XCTAssertEqual(error as? VaultError, .rootIsNotADirectory(path: file.path))
        }
    }

    // MARK: - Daily note URL (UTC)

    func testDailyNoteURLUsesUTCCalendarDay() throws {
        let vault = try Vault(root: Fixtures.vault)
        let url = vault.dailyNoteURL(on: utcDate("2026-08-07T12:00:00Z"))
        XCTAssertEqual(url, Fixtures.vault.appendingPathComponent("daily/2026-08-07.md"))
    }

    func testDailyNoteURLFlipsAtUTCMidnight() throws {
        let vault = try Vault(root: Fixtures.vault)
        XCTAssertEqual(
            vault.dailyNoteURL(on: utcDate("2026-08-07T23:59:59Z")).lastPathComponent,
            "2026-08-07.md"
        )
        XCTAssertEqual(
            vault.dailyNoteURL(on: utcDate("2026-08-08T00:00:01Z")).lastPathComponent,
            "2026-08-08.md"
        )
    }

    func testTemplatesDailyURL() throws {
        let vault = try Vault(root: Fixtures.vault)
        XCTAssertEqual(
            vault.templatesDailyURL,
            Fixtures.vault.appendingPathComponent("templates/daily.md")
        )
    }

    // MARK: - UTC stamps

    func testDayAndTimeStampsAreZeroPaddedUTC() {
        let date = utcDate("2026-01-05T07:05:59Z")
        XCTAssertEqual(Vault.dayStamp(on: date), "2026-01-05")
        XCTAssertEqual(Vault.timeStamp(on: date), "07:05")
    }

    // MARK: - Inbox glob

    func testInboxURLFindsFixtureInbox() throws {
        let vault = try Vault(root: Fixtures.vault)
        XCTAssertEqual(vault.inboxURL()?.lastPathComponent, "000 Inbox.md")
    }

    func testInboxURLTieBreaksLexicographically() throws {
        let second = tempRoot.appendingPathComponent("000 Aardvark.md")
        try Data("# Second inbox\n".utf8).write(to: second)
        XCTAssertEqual(try tempVault().inboxURL()?.lastPathComponent, "000 Aardvark.md")
    }

    func testInboxURLNilWhenNoInboxNote() throws {
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("000 Inbox.md"))
        XCTAssertNil(try tempVault().inboxURL())
    }

    func testInboxURLIsNonRecursive() throws {
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("000 Inbox.md"))
        let nestedDir = tempRoot.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Data("# Nested\n".utf8).write(to: nestedDir.appendingPathComponent("000 Deep.md"))
        XCTAssertNil(try tempVault().inboxURL(), "000*.md must only match at the vault root")
    }

    func testInboxURLExtensionMatchIsCaseSensitive() throws {
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("000 Inbox.md"))
        try Data("# Upper\n".utf8).write(to: tempRoot.appendingPathComponent("000 Upper.MD"))
        XCTAssertNil(try tempVault().inboxURL(), "glob 000*.md is case-sensitive")
    }

    func testInboxURLIgnoresDirectoryNamedLikeInboxNote() throws {
        // "000 Archive.md" sorts before "000 Inbox.md" — if directories were
        // eligible it would win the tie-break and every append would EISDIR.
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("000 Archive.md", isDirectory: true),
            withIntermediateDirectories: false
        )
        XCTAssertEqual(try tempVault().inboxURL()?.lastPathComponent, "000 Inbox.md")
    }

    func testInboxURLNilWhenOnlyDirectoriesMatchTheGlob() throws {
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("000 Inbox.md"))
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("000 Archive.md", isDirectory: true),
            withIntermediateDirectories: false
        )
        XCTAssertNil(try tempVault().inboxURL(), "a directory is never the inbox note")
    }
}
