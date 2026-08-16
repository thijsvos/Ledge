@testable import LedgeCore
import XCTest

/// Whether `/undo` may apply its stored record to the vault now configured.
///
/// This rule used to live in `AgentRunController`, where nothing could test it,
/// and it was wrong: it compared against the vault of the last RUN rather than
/// the configured one, so switching vaults in Settings never refused. Human QA
/// found that. The rule moved here so it cannot regress silently.
final class UndoDecisionTests: XCTestCase {
    private func record(touching name: String = "notes/a.md") -> RunUndoRecord {
        var record = RunUndoRecord()
        record.record(url: URL(fileURLWithPath: "/vault/\(name)"), before: "before")
        return record
    }

    private func stored(_ vaultPath: String) -> StoredUndo {
        StoredUndo(record: record(), vaultPath: vaultPath)
    }

    // MARK: - Nothing to undo

    func testNoStoredRecordIsNothingRecorded() {
        XCTAssertEqual(
            RunUndo.decide(stored: nil, configuredVaultPath: "/vault"),
            .nothingRecorded
        )
    }

    /// Distinct from "another vault": with no record at all the vault is
    /// irrelevant, and the peek says so.
    func testNoRecordWinsOverAMissingVault() {
        XCTAssertEqual(
            RunUndo.decide(stored: nil, configuredVaultPath: nil),
            .nothingRecorded
        )
    }

    // MARK: - The vault must match

    func testMatchingVaultRestores() {
        XCTAssertEqual(
            RunUndo.decide(stored: stored("/vault"), configuredVaultPath: "/vault"),
            .restore(record())
        )
    }

    /// The bug QA found: a record from one vault must never be applied while
    /// another is configured.
    func testDifferentVaultIsRefused() {
        XCTAssertEqual(
            RunUndo.decide(stored: stored("/vault"), configuredVaultPath: "/elsewhere"),
            .recordedForAnotherVault
        )
    }

    /// A prefix is not a match — `/vault-backup` must not read as `/vault`,
    /// the same trap `Vault.isDescendant` guards against.
    func testVaultPrefixIsNotAMatch() {
        XCTAssertEqual(
            RunUndo.decide(stored: stored("/vault"), configuredVaultPath: "/vault-backup"),
            .recordedForAnotherVault
        )
    }

    func testNoVaultConfiguredIsRefusedRatherThanRestored() {
        XCTAssertEqual(
            RunUndo.decide(stored: stored("/vault"), configuredVaultPath: nil),
            .recordedForAnotherVault
        )
        XCTAssertEqual(
            RunUndo.decide(stored: stored("/vault"), configuredVaultPath: ""),
            .recordedForAnotherVault
        )
    }

    // MARK: - The same folder spelled differently is still the same folder

    func testTrailingSlashStillMatches() {
        XCTAssertEqual(
            RunUndo.decide(stored: stored("/vault/"), configuredVaultPath: "/vault"),
            .restore(record())
        )
    }

    func testRelativeSegmentsAreStandardizedAway() {
        XCTAssertEqual(
            RunUndo.decide(stored: stored("/vault/notes/.."), configuredVaultPath: "/vault"),
            .restore(record())
        )
    }

    /// Settings stores whatever the user typed, which may contain a tilde,
    /// while a run records the expanded path.
    func testTildeExpandsOnBothSides() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            RunUndo.decide(stored: stored("\(home)/vault"), configuredVaultPath: "~/vault"),
            .restore(record())
        )
        XCTAssertEqual(
            RunUndo.decide(stored: stored("~/vault"), configuredVaultPath: "\(home)/vault"),
            .restore(record())
        )
    }

    /// Case matters on a case-sensitive volume, and guessing wrong is worse
    /// than refusing — a refusal costs one message, a wrong restore costs data.
    func testCaseDifferenceIsRefused() {
        XCTAssertEqual(
            RunUndo.decide(stored: stored("/Vault"), configuredVaultPath: "/vault"),
            .recordedForAnotherVault
        )
    }
}
