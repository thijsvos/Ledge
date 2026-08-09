@testable import LedgeCore
import XCTest

/// SlashCommandCatalog: scan (namespacing, skills, frontmatter, dedupe,
/// ordering, hidden/symlink/depth skips, missing dirs) and matching
/// (case-insensitive prefix, empty prefix = all). All fixture trees are built
/// in per-test temp directories — nothing committed, nothing under the real
/// `~/.claude` is ever touched.
final class SlashCommandCatalogTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var vault: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-slash-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture helpers

    /// Writes `<base>/.claude/commands/<relativePath>` (creating parents).
    @discardableResult
    private func writeCommand(
        base: URL, _ relativePath: String, contents: String = "Do the thing.\n"
    ) throws -> URL {
        let url = base.appendingPathComponent(".claude/commands/" + relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Writes `<base>/.claude/skills/<directory>/SKILL.md`.
    @discardableResult
    private func writeSkill(
        base: URL, directory: String, contents: String = "A skill.\n"
    ) throws -> URL {
        let url = base.appendingPathComponent(".claude/skills/\(directory)/SKILL.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func scan() -> [SlashCommand] {
        SlashCommandCatalog.scan(vaultRoot: vault, userHome: home)
    }

    // MARK: - Command discovery & namespacing

    func testTopLevelCommandNameIsFilenameWithoutExtension() throws {
        try writeCommand(base: home, "review.md")
        XCTAssertEqual(scan().map(\.name), ["review"])
    }

    func testNestedCommandNamespacesWithColons() throws {
        try writeCommand(base: home, "foo/bar.md")
        let commands = scan()
        XCTAssertEqual(commands.map(\.name), ["foo:bar"])
        XCTAssertEqual(commands.first?.source, .userCommand)
    }

    func testOnlyTheMdExtensionIsStripped() throws {
        try writeCommand(base: home, "foo.bar.md")
        try writeCommand(base: home, "notes.txt") // non-markdown: ignored
        XCTAssertEqual(scan().map(\.name), ["foo.bar"])
    }

    func testDepthIsCappedAtThreeComponents() throws {
        try writeCommand(base: home, "a/b/c.md") // 3 components: kept
        try writeCommand(base: home, "a/b/c/d.md") // 4 components: skipped
        XCTAssertEqual(scan().map(\.name), ["a:b:c"])
    }

    func testHiddenFilesAndDirectoriesAreSkipped() throws {
        try writeCommand(base: home, ".secret.md")
        try writeCommand(base: home, ".hidden/inner.md")
        try writeCommand(base: home, "visible.md")
        try writeSkill(base: home, directory: ".hiddenskill")
        XCTAssertEqual(scan().map(\.name), ["visible"])
    }

    func testSymlinkedFilesAndDirectoriesAreNeverFollowed() throws {
        let real = try writeCommand(base: home, "real.md")
        let commandsDir = real.deletingLastPathComponent()
        // File symlink beside it, directory symlink to the commands dir
        // itself (a would-be cycle), and a symlinked SKILL.md.
        try FileManager.default.createSymbolicLink(
            at: commandsDir.appendingPathComponent("alias.md"), withDestinationURL: real
        )
        try FileManager.default.createSymbolicLink(
            at: commandsDir.appendingPathComponent("loop"), withDestinationURL: commandsDir
        )
        let skillDir = home.appendingPathComponent(".claude/skills/linked", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skillDir.appendingPathComponent("SKILL.md"), withDestinationURL: real
        )
        XCTAssertEqual(scan().map(\.name), ["real"])
    }

    func testSymlinkedCommandsRootIsNeverFollowed() throws {
        // §2 invariant: the enumeration ROOTS get the same symlink
        // discipline as their entries. A crafted vault whose
        // `.claude/commands` is a symlink (here: at the user's commands
        // tree, standing in for `~/.claude` redirection) contributes
        // nothing — the home tree is still scanned as itself.
        try writeCommand(base: home, "real.md")
        let vaultClaude = vault.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultClaude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: vaultClaude.appendingPathComponent("commands"),
            withDestinationURL: home.appendingPathComponent(".claude/commands", isDirectory: true)
        )
        let commands = scan()
        XCTAssertEqual(commands.map(\.name), ["real"])
        XCTAssertEqual(commands.map(\.source), [.userCommand]) // never .projectCommand
    }

    func testSymlinkedSkillsRootIsNeverFollowed() throws {
        try writeSkill(base: home, directory: "realskill")
        let vaultClaude = vault.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultClaude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: vaultClaude.appendingPathComponent("skills"),
            withDestinationURL: home.appendingPathComponent(".claude/skills", isDirectory: true)
        )
        let commands = scan()
        XCTAssertEqual(commands.map(\.name), ["realskill"])
        XCTAssertEqual(commands.map(\.source), [.userSkill]) // never .projectSkill
    }

    func testSymlinkedClaudeDirectoryIsNeverFollowed() throws {
        try writeCommand(base: home, "real.md")
        // The whole `<vault>/.claude` is a symlink at the user's `.claude`.
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent(".claude"),
            withDestinationURL: home.appendingPathComponent(".claude", isDirectory: true)
        )
        let commands = scan()
        XCTAssertEqual(commands.map(\.name), ["real"])
        XCTAssertEqual(commands.map(\.source), [.userCommand])
    }

    func testMissingDirectoriesContributeNothing() {
        // Neither base has a .claude directory at all.
        XCTAssertEqual(scan(), [])
    }

    func testNilVaultRootScansUserLevelOnly() throws {
        try writeCommand(base: home, "mine.md")
        try writeCommand(base: vault, "theirs.md")
        let commands = SlashCommandCatalog.scan(vaultRoot: nil, userHome: home)
        XCTAssertEqual(commands.map(\.name), ["mine"])
        XCTAssertEqual(commands.map(\.source), [.userCommand])
    }

    // MARK: - Skills

    func testSkillNameComesFromFrontmatterWhenPresent() throws {
        try writeSkill(
            base: home,
            directory: "deploy-helper",
            contents: "---\nname: deploy\ndescription: Ships it\n---\nBody.\n"
        )
        let commands = scan()
        XCTAssertEqual(commands.map(\.name), ["deploy"])
        XCTAssertEqual(commands.first?.description, "Ships it")
        XCTAssertEqual(commands.first?.source, .userSkill)
    }

    func testSkillWithoutFrontmatterNameUsesDirectoryName() throws {
        try writeSkill(base: home, directory: "plainskill", contents: "No frontmatter here.\n")
        let commands = scan()
        XCTAssertEqual(commands.map(\.name), ["plainskill"])
        XCTAssertNil(commands.first?.description)
    }

    func testSkillDirectoryWithoutSkillFileIsSkipped() throws {
        let empty = home.appendingPathComponent(".claude/skills/hollow", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(scan(), [])
    }

    // MARK: - Frontmatter extraction

    func testDescriptionAndArgumentHintAreExtracted() throws {
        try writeCommand(
            base: home,
            "plan.md",
            contents: "---\ndescription: Plans the day\nargument-hint: [date]\n---\nBody.\n"
        )
        let command = try XCTUnwrap(scan().first)
        XCTAssertEqual(command.description, "Plans the day")
        XCTAssertEqual(command.argumentHint, "[date]")
    }

    func testQuotedValuesAndCRLFAreTolerated() throws {
        let contents = "---\r\ndescription: \"Quoted: value\"\r\nargument-hint: '[x]'\r\n---\r\nBody.\r\n"
        try writeCommand(base: home, "crlf.md", contents: contents)
        let command = try XCTUnwrap(scan().first)
        XCTAssertEqual(command.description, "Quoted: value")
        XCTAssertEqual(command.argumentHint, "[x]")
    }

    func testFileWithoutFrontmatterYieldsNilFields() throws {
        try writeCommand(base: home, "bare.md", contents: "Just a body, no frontmatter.\n")
        let command = try XCTUnwrap(scan().first)
        XCTAssertNil(command.description)
        XCTAssertNil(command.argumentHint)
    }

    func testUnclosedFrontmatterIsBrokenAndYieldsNilFields() throws {
        try writeCommand(base: home, "broken.md", contents: "---\ndescription: dangling\n")
        let command = try XCTUnwrap(scan().first)
        XCTAssertNil(command.description)
    }

    func testFrontmatterClosingBeyondFourKilobytesYieldsNilFields() throws {
        // The closing --- sits past the 4 KB read limit, so the block is
        // treated as unclosed → all nil. Also proves giant files never stall
        // the scan: only the first 4 KB is read.
        let filler = String(repeating: "filler line without any delimiter\n", count: 200)
        try writeCommand(
            base: home,
            "huge.md",
            contents: "---\ndescription: early\n" + filler + "---\nBody.\n"
        )
        XCTAssertGreaterThan(filler.utf8.count, Frontmatter.maxBytes)
        let command = try XCTUnwrap(scan().first)
        XCTAssertNil(command.description)
    }

    func testEmptyAndUnknownFrontmatterValuesAreIgnored() throws {
        try writeCommand(
            base: home,
            "sparse.md",
            contents: "---\ndescription:\nmodel: opus\nargument-hint: [n]\n---\n"
        )
        let command = try XCTUnwrap(scan().first)
        XCTAssertNil(command.description) // empty value = absent
        XCTAssertEqual(command.argumentHint, "[n]")
    }

    // MARK: - Ordering & dedupe

    func testGroupOrderThenAlphabeticalWithinGroup() throws {
        try writeCommand(base: vault, "zeta.md")
        try writeCommand(base: vault, "alpha.md")
        try writeSkill(base: vault, directory: "vskill")
        try writeCommand(base: home, "beta.md")
        try writeSkill(base: home, directory: "uskill")
        let commands = scan()
        XCTAssertEqual(commands.map(\.name), ["alpha", "zeta", "vskill", "beta", "uskill"])
        XCTAssertEqual(
            commands.map(\.source),
            [.projectCommand, .projectCommand, .projectSkill, .userCommand, .userSkill]
        )
    }

    func testAlphabeticalOrderingIsCaseInsensitive() throws {
        try writeCommand(base: home, "Bravo.md")
        try writeCommand(base: home, "alpha.md")
        try writeCommand(base: home, "charlie.md")
        XCTAssertEqual(scan().map(\.name), ["alpha", "Bravo", "charlie"])
    }

    func testDedupeProjectBeatsUserAndCommandBeatsSkill() throws {
        // Same name from all four sources → the project command wins.
        try writeCommand(base: vault, "ship.md")
        try writeSkill(base: vault, directory: "ship")
        try writeCommand(base: home, "ship.md")
        try writeSkill(base: home, directory: "ship")
        // Same name from project skill and user command → the project skill
        // wins (project beats user before command beats skill).
        try writeSkill(base: vault, directory: "lint")
        try writeCommand(base: home, "lint.md")
        let commands = scan()
        XCTAssertEqual(commands.map(\.name), ["ship", "lint"])
        XCTAssertEqual(commands.map(\.source), [.projectCommand, .projectSkill])
    }

    // MARK: - matching(prefix:)

    func testMatchingIsCaseInsensitiveAndPreservesOrder() throws {
        try writeCommand(base: home, "Review.md")
        try writeCommand(base: home, "release.md")
        try writeCommand(base: home, "plan.md")
        let catalog = SlashCommandCatalog(commands: scan())
        XCTAssertEqual(catalog.matching(prefix: "re").map(\.name), ["release", "Review"])
        XCTAssertEqual(catalog.matching(prefix: "REL").map(\.name), ["release"])
        XCTAssertEqual(catalog.matching(prefix: "x"), [])
    }

    func testMatchingEmptyPrefixReturnsAll() {
        let commands = [
            SlashCommand(name: "a", source: .userCommand),
            SlashCommand(name: "b", source: .userSkill),
        ]
        XCTAssertEqual(SlashCommandCatalog(commands: commands).matching(prefix: ""), commands)
    }

    // MARK: - restoringCommandSlash(_:)

    func testRestoringCommandSlashPrependsWhenFirstTokenNamesACommand() {
        let catalog = SlashCommandCatalog(commands: [
            SlashCommand(name: "dep-check", source: .userCommand),
        ])
        // The typeahead's completion text ("/name " → prompt "name ").
        XCTAssertEqual(catalog.restoringCommandSlash("dep-check "), "/dep-check ")
        XCTAssertEqual(catalog.restoringCommandSlash("dep-check"), "/dep-check")
        XCTAssertEqual(
            catalog.restoringCommandSlash("dep-check src only"), "/dep-check src only"
        )
    }

    func testRestoringCommandSlashLeavesOtherPromptsUnchanged() {
        let catalog = SlashCommandCatalog(commands: [
            SlashCommand(name: "fix-ci", source: .userCommand),
        ])
        XCTAssertEqual(catalog.restoringCommandSlash("fix the typo"), "fix the typo") // prose
        XCTAssertEqual(catalog.restoringCommandSlash("fix"), "fix") // prefix, not the name
        XCTAssertEqual(catalog.restoringCommandSlash("fix-cish"), "fix-cish") // longer token
        XCTAssertEqual(catalog.restoringCommandSlash("Fix-CI now"), "Fix-CI now") // exact case only
        XCTAssertEqual(catalog.restoringCommandSlash(""), "")
        XCTAssertEqual(catalog.restoringCommandSlash(" fix-ci"), " fix-ci") // empty first token
        XCTAssertEqual(SlashCommandCatalog().restoringCommandSlash("anything"), "anything")
    }
}
