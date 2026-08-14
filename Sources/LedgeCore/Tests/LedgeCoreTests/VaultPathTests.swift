@testable import LedgeCore
import XCTest

/// The vault fence (§2.3, §2.5): every path an edit plan names must be proven
/// to live inside the vault before Ledge writes to it. Mutating tests run
/// against a fresh temp copy of the fixture vault.
final class VaultPathTests: XCTestCase {
    private var tempRoot: URL!
    private var outsideDir: URL!

    override func setUpWithError() throws {
        tempRoot = try Fixtures.makeTempVaultCopy()
        // A sibling of the vault, never inside it — the target every escape
        // attempt below tries to reach.
        outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        if let outsideDir {
            try? FileManager.default.removeItem(at: outsideDir)
        }
        tempRoot = nil
        outsideDir = nil
    }

    private func tempVault() throws -> Vault {
        try Vault(root: tempRoot)
    }

    /// The vault root as `resolve` sees it — symlinks resolved, so /var and
    /// /private/var compare equal.
    private var resolvedRoot: URL {
        tempRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func assertRejects(
        _ path: String,
        _ expected: Vault.PathRejection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let vault = try tempVault()
        XCTAssertThrowsError(try vault.resolve(relativePath: path), file: file, line: line) { error in
            XCTAssertEqual(error as? Vault.PathRejection, expected, file: file, line: line)
        }
    }

    // MARK: - Accepted paths

    func testResolvesExistingFileInsideVault() throws {
        let url = try tempVault().resolve(relativePath: "daily/2026-08-07.md")
        XCTAssertEqual(url, resolvedRoot.appendingPathComponent("daily/2026-08-07.md"))
    }

    /// The `create` case: the leaf does not exist yet, so symlinks cannot be
    /// resolved on the whole path. It must still resolve.
    func testResolvesFileThatDoesNotExistYet() throws {
        let url = try tempVault().resolve(relativePath: "notes/brand-new.md")
        XCTAssertEqual(url, resolvedRoot.appendingPathComponent("notes/brand-new.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Neither does the intermediate folder — the applier creates it.
    func testResolvesThroughFoldersThatDoNotExistYet() throws {
        let url = try tempVault().resolve(relativePath: "projects/2026/kickoff.md")
        XCTAssertEqual(url, resolvedRoot.appendingPathComponent("projects/2026/kickoff.md"))
    }

    func testLeadingDotSlashIsStripped() throws {
        let url = try tempVault().resolve(relativePath: "./notes/foo.md")
        XCTAssertEqual(url, resolvedRoot.appendingPathComponent("notes/foo.md"))
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        let url = try tempVault().resolve(relativePath: "  notes/foo.md\n")
        XCTAssertEqual(url, resolvedRoot.appendingPathComponent("notes/foo.md"))
    }

    // MARK: - Shape refusals

    func testEmptyPathIsRefused() throws {
        try assertRejects("", .empty)
        try assertRejects("   ", .empty)
    }

    func testAbsolutePathIsRefused() throws {
        try assertRejects("/etc/passwd.md", .absolutePath("/etc/passwd.md"))
    }

    func testTildePathIsRefused() throws {
        try assertRejects("~/notes.md", .tildePath("~/notes.md"))
    }

    func testNonMarkdownPathIsRefused() throws {
        try assertRejects("notes/foo.txt", .notMarkdown("notes/foo.txt"))
        try assertRejects("notes/foo", .notMarkdown("notes/foo"))
    }

    /// Case-sensitive, matching `inboxURL()`'s `000*.md` glob convention.
    func testMarkdownExtensionMatchIsCaseSensitive() throws {
        try assertRejects("notes/foo.MD", .notMarkdown("notes/foo.MD"))
    }

    // MARK: - Traversal refusals

    func testParentTraversalIsRefused() throws {
        try assertRejects("../outside.md", .parentTraversal("../outside.md"))
        try assertRejects("notes/../../outside.md", .parentTraversal("notes/../../outside.md"))
    }

    /// `..` is refused outright rather than normalized — a slip that lands
    /// inside the vault only after collapsing `..` is still a slip Ledge
    /// declines to reason about.
    func testParentTraversalIsRefusedEvenWhenItStaysInside() throws {
        try assertRejects("notes/../daily/2026-08-07.md", .parentTraversal("notes/../daily/2026-08-07.md"))
    }

    // MARK: - Hidden-path refusals

    /// An agent that could write `.claude/commands/*.md` would be authoring
    /// slash commands SlashCommandCatalog later offers the user.
    func testHiddenDirectoryIsRefused() throws {
        try assertRejects(".claude/commands/evil.md", .hiddenComponent(".claude/commands/evil.md"))
    }

    func testNestedHiddenDirectoryIsRefused() throws {
        try assertRejects("notes/.git/config.md", .hiddenComponent("notes/.git/config.md"))
    }

    func testHiddenFileIsRefused() throws {
        try assertRejects(".secret.md", .hiddenComponent(".secret.md"))
    }

    // MARK: - Symlink escapes

    func testSymlinkedFileLeafPointingOutsideIsRefused() throws {
        let target = outsideDir.appendingPathComponent("stolen.md")
        try Data("# outside\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: tempRoot.appendingPathComponent("notes/escape.md"),
            withDestinationURL: target
        )
        try assertRejects("notes/escape.md", .escapesVault("notes/escape.md"))
    }

    func testSymlinkedDirectoryPointingOutsideIsRefused() throws {
        try FileManager.default.createSymbolicLink(
            at: tempRoot.appendingPathComponent("notes/out"),
            withDestinationURL: outsideDir
        )
        try assertRejects("notes/out/stolen.md", .escapesVault("notes/out/stolen.md"))
    }

    /// The escape is caught even when the leaf beneath the linked folder does
    /// not exist yet — the containment check runs on every existing component,
    /// not just on the leaf.
    func testWriteThroughSymlinkedDirectoryToNewFileIsRefused() throws {
        try FileManager.default.createSymbolicLink(
            at: tempRoot.appendingPathComponent("notes/out"),
            withDestinationURL: outsideDir
        )
        try assertRejects("notes/out/brand-new.md", .escapesVault("notes/out/brand-new.md"))
    }

    /// A symlink that stays inside the vault is fine.
    func testSymlinkPointingInsideVaultIsAccepted() throws {
        try FileManager.default.createSymbolicLink(
            at: tempRoot.appendingPathComponent("notes/inside"),
            withDestinationURL: tempRoot.appendingPathComponent("daily", isDirectory: true)
        )
        let url = try tempVault().resolve(relativePath: "notes/inside/2026-08-07.md")
        XCTAssertEqual(url, resolvedRoot.appendingPathComponent("daily/2026-08-07.md"))
    }

    // MARK: - Directory targets

    func testExistingDirectoryNamedLikeANoteIsRefused() throws {
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("notes/folder.md", isDirectory: true),
            withIntermediateDirectories: false
        )
        try assertRejects("notes/folder.md", .isADirectory("notes/folder.md"))
    }

    // MARK: - Containment helper

    /// `/vault-backup` must never read as a child of `/vault`.
    func testSiblingWithSharedPrefixIsNotADescendant() {
        let root = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)
        XCTAssertFalse(
            Vault.isDescendant(URL(fileURLWithPath: "/tmp/vault-backup/note.md"), of: root)
        )
        XCTAssertTrue(
            Vault.isDescendant(URL(fileURLWithPath: "/tmp/vault/note.md"), of: root)
        )
    }

    func testRootItselfIsNotADescendant() {
        let root = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)
        XCTAssertFalse(Vault.isDescendant(URL(fileURLWithPath: "/tmp/vault"), of: root))
    }
}
