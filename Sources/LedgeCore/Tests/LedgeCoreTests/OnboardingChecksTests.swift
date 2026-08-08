@testable import LedgeCore
import XCTest

/// §7 onboarding checks: the full simulation matrix (binary missing/present,
/// vault unset/invalid/valid, CLAUDE.md absent/present, clause absent/present,
/// git/checkpoints recommendation incl. `.register/config.json` parsing) plus
/// the headless-clause append (idempotency, verbatim text, missing file).
final class OnboardingChecksTests: XCTestCase {
    // MARK: - Fixture plumbing (pure, injected — no real filesystem)

    /// Builds injected file checks from plain dictionaries. `vaultError` nil
    /// means every validated path is a valid vault.
    private func fileChecks(
        directories: Set<String> = [],
        files: [String: String] = [:],
        vaultError: VaultError? = nil
    ) -> OnboardingFileChecks {
        OnboardingFileChecks(
            directoryExists: { directories.contains($0) },
            fileExists: { files[$0] != nil },
            fileContents: { files[$0] },
            validateVault: { _ in vaultError }
        )
    }

    private let clause = OnboardingChecks.headlessClause

    // MARK: - Check 1: binary

    func testBinaryMissing() {
        let report = OnboardingChecks.run(
            binaryResolution: nil, vaultPath: nil, fileChecks: fileChecks()
        )
        XCTAssertEqual(report.binary, .notFound)
    }

    func testBinaryFoundNamesResolvedPath() {
        let report = OnboardingChecks.run(
            binaryResolution: "/opt/homebrew/bin/claude", vaultPath: nil, fileChecks: fileChecks()
        )
        XCTAssertEqual(report.binary, .found(path: "/opt/homebrew/bin/claude"))
    }

    /// §6: the not-found state links to the install docs — display-only.
    func testInstallDocsURLIsTheDocumentedOne() {
        XCTAssertEqual(
            OnboardingChecks.installDocsURL,
            "https://docs.anthropic.com/en/docs/claude-code"
        )
    }

    // MARK: - Check 2: vault

    func testVaultUnsetSkipsDependentChecks() {
        let report = OnboardingChecks.run(
            binaryResolution: nil, vaultPath: nil, fileChecks: fileChecks()
        )
        XCTAssertEqual(report.vault, .notConfigured)
        XCTAssertEqual(report.claudeMD, .skipped)
        XCTAssertEqual(report.checkpoints, .skipped)
        XCTAssertEqual(report.headlessClause, .skipped)
    }

    func testVaultEmptyStringCountsAsUnset() {
        let report = OnboardingChecks.run(
            binaryResolution: nil, vaultPath: "", fileChecks: fileChecks()
        )
        XCTAssertEqual(report.vault, .notConfigured)
    }

    func testVaultInvalidCarriesTypedErrorAndSkipsDependentChecks() {
        let error = VaultError.rootDoesNotExist(path: "/nope")
        let report = OnboardingChecks.run(
            binaryResolution: nil, vaultPath: "/nope", fileChecks: fileChecks(vaultError: error)
        )
        XCTAssertEqual(report.vault, .invalid(error))
        XCTAssertEqual(report.claudeMD, .skipped)
        XCTAssertEqual(report.checkpoints, .skipped)
        XCTAssertEqual(report.headlessClause, .skipped)
    }

    func testVaultValidReportsExpandedPath() {
        let report = OnboardingChecks.run(
            binaryResolution: nil, vaultPath: "/v", fileChecks: fileChecks()
        )
        XCTAssertEqual(report.vault, .valid(path: "/v"))
    }

    func testVaultPathTildeIsExpandedBeforeValidation() {
        let seen = OSAllocatedUnfairLockBox<[String]>(initialState: [])
        let checks = OnboardingFileChecks(
            directoryExists: { _ in false },
            fileExists: { _ in false },
            fileContents: { _ in nil },
            validateVault: { path in
                seen.withLock { $0.append(path) }
                return nil
            }
        )
        let report = OnboardingChecks.run(
            binaryResolution: nil, vaultPath: "~/vault", fileChecks: checks
        )
        let expanded = ("~/vault" as NSString).expandingTildeInPath
        XCTAssertEqual(seen.withLock { $0 }, [expanded])
        XCTAssertEqual(report.vault, .valid(path: expanded))
    }

    // MARK: - Check 3: CLAUDE.md presence

    func testClaudeMDMissing() {
        let report = OnboardingChecks.run(
            binaryResolution: nil, vaultPath: "/v", fileChecks: fileChecks()
        )
        XCTAssertEqual(report.claudeMD, .missing)
        XCTAssertEqual(report.headlessClause, .skipped, "no CLAUDE.md → clause check skipped")
    }

    func testClaudeMDPresent() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(files: ["/v/CLAUDE.md": "# contract\n"])
        )
        XCTAssertEqual(report.claudeMD, .present)
    }

    // MARK: - Check 4: git / checkpoints recommendation

    func testNoGitMeansNothingToRecommend() {
        let report = OnboardingChecks.run(
            binaryResolution: nil, vaultPath: "/v", fileChecks: fileChecks()
        )
        XCTAssertEqual(report.checkpoints, .noGit)
    }

    func testGitWithoutRegisterConfigRecommendsEnabling() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(directories: ["/v/.git"])
        )
        XCTAssertEqual(report.checkpoints, .recommendEnabling)
    }

    /// Linked worktrees and submodules have `.git` as a regular FILE
    /// ("gitdir: …"), not a directory — still a git-managed vault, so the
    /// recommendation must fire.
    func testGitFileWorktreeVariantRecommendsEnabling() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(files: ["/v/.git": "gitdir: /repos/main/.git/worktrees/v\n"])
        )
        XCTAssertEqual(report.checkpoints, .recommendEnabling)
    }

    func testGitFileWorktreeVariantWithCheckpointsTrueIsEnabled() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(files: [
                "/v/.git": "gitdir: /repos/main/.git/worktrees/v\n",
                "/v/.register/config.json": #"{"checkpoints": true}"#,
            ])
        )
        XCTAssertEqual(report.checkpoints, .enabled)
    }

    func testGitWithCheckpointsTrueIsEnabled() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(
                directories: ["/v/.git"],
                files: ["/v/.register/config.json": #"{"checkpoints": true, "other": 1}"#]
            )
        )
        XCTAssertEqual(report.checkpoints, .enabled)
    }

    func testGitWithCheckpointsFalseRecommendsEnabling() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(
                directories: ["/v/.git"],
                files: ["/v/.register/config.json": #"{"checkpoints": false}"#]
            )
        )
        XCTAssertEqual(report.checkpoints, .recommendEnabling)
    }

    func testMalformedConfigRecommendsEnabling() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(
                directories: ["/v/.git"],
                files: ["/v/.register/config.json": "not json {"]
            )
        )
        XCTAssertEqual(report.checkpoints, .recommendEnabling)
    }

    func testNonBooleanCheckpointsValueRecommendsEnabling() {
        XCTAssertFalse(OnboardingChecks.checkpointsEnabled(configJSON: #"{"checkpoints": "true"}"#))
        XCTAssertFalse(OnboardingChecks.checkpointsEnabled(configJSON: #"{"checkpoints": 1}"#))
        XCTAssertFalse(OnboardingChecks.checkpointsEnabled(configJSON: #"["checkpoints"]"#))
        XCTAssertFalse(OnboardingChecks.checkpointsEnabled(configJSON: nil))
        XCTAssertTrue(OnboardingChecks.checkpointsEnabled(configJSON: #"{"checkpoints":true}"#))
    }

    // MARK: - Check 5: headless clause

    func testClausePresentDetectedByExactSubstring() {
        let contents = "# contract\n\n" + clause + "\n\n## More\n"
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(files: ["/v/CLAUDE.md": contents])
        )
        XCTAssertEqual(report.headlessClause, .present)
    }

    func testClauseMissingOffersAppend() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(files: ["/v/CLAUDE.md": "# contract\n"])
        )
        XCTAssertEqual(report.headlessClause, .missing)
    }

    /// A CLAUDE.md saved with CRLF endings ("\r\n" is ONE Swift grapheme, so
    /// an LF pattern never matches raw CRLF text) must still count as
    /// clause-present — otherwise the one-click append would duplicate it.
    func testClausePresentWithCRLFLineEndingsDetected() {
        let crlfClause = clause.replacingOccurrences(of: "\n", with: "\r\n")
        let contents = "# contract\r\n\r\n" + crlfClause + "\r\n"
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: "/v",
            fileChecks: fileChecks(files: ["/v/CLAUDE.md": contents])
        )
        XCTAssertEqual(report.headlessClause, .present)
    }

    // MARK: - Headless clause: verbatim text (§7, char-for-char)

    func testHeadlessClauseIsVerbatimSpecText() {
        // The exact §7 markdown block, reproduced here independently so any
        // drift in the constant fails char-for-char.
        let expected = "## Headless invocations (Ledge)\n"
            + "When run non-interactively (claude -p): never ask questions. Make the smallest\n"
            + "conforming edit, record any assumption inline in the affected note as\n"
            + "\"assumption: \u{2026}\", and do not run shell, git, or register commands."
        XCTAssertEqual(Array(clause.unicodeScalars), Array(expected.unicodeScalars))
    }

    // MARK: - appendingHeadlessClause (pure)

    func testAppendToFileEndingInSingleNewlineInsertsBlankLine() {
        let result = OnboardingChecks.appendingHeadlessClause(to: "# contract\n")
        XCTAssertEqual(result, "# contract\n\n" + clause + "\n")
    }

    func testAppendToFileWithoutTrailingNewlineInsertsBlankLine() {
        let result = OnboardingChecks.appendingHeadlessClause(to: "# contract")
        XCTAssertEqual(result, "# contract\n\n" + clause + "\n")
    }

    func testAppendToFileAlreadyEndingInBlankLineAddsNoExtraSeparator() {
        let result = OnboardingChecks.appendingHeadlessClause(to: "# contract\n\n")
        XCTAssertEqual(result, "# contract\n\n" + clause + "\n")
    }

    func testAppendToEmptyContentsIsJustTheClause() {
        XCTAssertEqual(OnboardingChecks.appendingHeadlessClause(to: ""), clause + "\n")
    }

    func testAppendIsIdempotent() {
        let once = OnboardingChecks.appendingHeadlessClause(to: "# contract\n")
        let twice = OnboardingChecks.appendingHeadlessClause(to: once)
        XCTAssertEqual(once, twice, "exact-substring check must prevent duplication")
    }

    func testAppendDetectsClauseAnywhereInTheFile() {
        let contents = clause + "\n\n## Later sections\n"
        XCTAssertEqual(OnboardingChecks.appendingHeadlessClause(to: contents), contents)
    }

    /// Idempotency must survive CRLF re-saves: the clause present with CRLF
    /// endings makes the append a no-op, never a duplicate.
    func testAppendIsNoOpWhenClausePresentWithCRLFEndings() {
        let crlfClause = clause.replacingOccurrences(of: "\n", with: "\r\n")
        let contents = "# contract\r\n\r\n" + crlfClause + "\r\n"
        XCTAssertEqual(OnboardingChecks.appendingHeadlessClause(to: contents), contents)
    }

    /// A CRLF file ending in "\r\n" ends in a newline — the separator logic
    /// must see that (via normalization) and insert exactly one blank line.
    func testAppendToCRLFFileEndingInSingleNewlineInsertsBlankLine() {
        let result = OnboardingChecks.appendingHeadlessClause(to: "# contract\r\n")
        XCTAssertEqual(result, "# contract\r\n\n" + clause + "\n")
    }

    // MARK: - appendHeadlessClause(toContentsOf:) (file-level)

    private func makeTempFile(_ contents: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-claudemd-\(UUID().uuidString).md")
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testFileAppendWritesExpectedContents() throws {
        let url = try makeTempFile("# contract\n")
        XCTAssertTrue(try OnboardingChecks.appendHeadlessClause(toContentsOf: url))
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "# contract\n\n" + clause + "\n")
    }

    func testFileAppendSecondCallIsNoOp() throws {
        let url = try makeTempFile("# contract\n")
        XCTAssertTrue(try OnboardingChecks.appendHeadlessClause(toContentsOf: url))
        let afterFirst = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(try OnboardingChecks.appendHeadlessClause(toContentsOf: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), afterFirst)
    }

    func testFileAppendThrowsOnMissingFile() throws {
        let url = try makeTempFile(nil)
        XCTAssertThrowsError(try OnboardingChecks.appendHeadlessClause(toContentsOf: url)) { error in
            XCTAssertEqual(
                error as? OnboardingChecks.HeadlessClauseError,
                .fileNotFound(path: url.path)
            )
        }
    }

    // MARK: - Live file checks against the fixture vault

    /// The `.live` seams answer correctly for a real vault on disk (the
    /// committed fixture): CLAUDE.md present, no .git, clause missing.
    func testLiveChecksAgainstFixtureVault() {
        let report = OnboardingChecks.run(
            binaryResolution: nil,
            vaultPath: Fixtures.vault.path
        )
        XCTAssertEqual(report.vault, .valid(path: Fixtures.vault.path))
        XCTAssertEqual(report.claudeMD, .present)
        XCTAssertEqual(report.checkpoints, .noGit)
        XCTAssertEqual(report.headlessClause, .missing)
    }
}

/// Tiny generic lock box for capturing values from @Sendable closures in tests.
private final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(initialState: Value) {
        value = initialState
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
