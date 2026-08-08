@testable import LedgeCore
import XCTest

/// §5 InstantCapture against a fresh temp copy of the fixture vault per test —
/// the committed fixtures are NEVER mutated. Covers appends, creation (from
/// template and minimal header), UTC rollover, inbox glob + tie-break +
/// fallback, unicode byte-exactness, and trailing-newline repair.
final class InstantCaptureTests: XCTestCase {
    private var root: URL!
    private var vault: Vault!

    override func setUpWithError() throws {
        root = try Fixtures.makeTempVaultCopy()
        vault = try Vault(root: root)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        vault = nil
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Daily: append to existing note

    func testAppendsToExistingDailyNote() throws {
        let noteURL = root.appendingPathComponent("daily/2026-08-07.md")
        let before = try contents(of: noteURL)

        let outcome = try InstantCapture.capture(
            "hello ledge",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-07T12:34:56Z")
        )

        XCTAssertEqual(outcome.fileURL, noteURL)
        XCTAssertEqual(outcome.target, .daily)
        XCTAssertFalse(outcome.fellBackToDaily)
        XCTAssertEqual(try contents(of: noteURL), before + "- 12:34Z hello ledge\n")
    }

    func testTimeStampIsZeroPadded() throws {
        let outcome = try InstantCapture.capture(
            "early",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-07T07:05:00Z")
        )
        XCTAssertTrue(try contents(of: outcome.fileURL).hasSuffix("- 07:05Z early\n"))
    }

    // MARK: - Daily: creation

    func testCreatesMissingDailyNoteFromTemplateWithDateSubstitution() throws {
        let outcome = try InstantCapture.capture(
            "first thought",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-09T10:00:30Z")
        )
        XCTAssertEqual(outcome.fileURL, root.appendingPathComponent("daily/2026-08-09.md"))
        XCTAssertEqual(
            try contents(of: outcome.fileURL),
            "# 2026-08-09\n\n## Log\n- 10:00Z first thought\n"
        )
    }

    func testCreatesMinimalHeaderWhenTemplateAbsent() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("templates/daily.md"))
        // Also drop the daily dir to prove the parent is created on demand.
        try FileManager.default.removeItem(at: root.appendingPathComponent("daily"))

        let outcome = try InstantCapture.capture(
            "minimal",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-09T10:00:30Z")
        )
        XCTAssertEqual(try contents(of: outcome.fileURL), "# 2026-08-09\n- 10:00Z minimal\n")
    }

    // MARK: - UTC rollover

    func testUTCMidnightRolloverFlipsTheFilename() throws {
        let beforeMidnight = try InstantCapture.capture(
            "late",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-08T23:59:30Z")
        )
        let afterMidnight = try InstantCapture.capture(
            "early",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-09T00:00:30Z")
        )

        XCTAssertEqual(beforeMidnight.fileURL.lastPathComponent, "2026-08-08.md")
        XCTAssertEqual(afterMidnight.fileURL.lastPathComponent, "2026-08-09.md")
        XCTAssertTrue(try contents(of: beforeMidnight.fileURL).hasSuffix("- 23:59Z late\n"))
        XCTAssertTrue(try contents(of: afterMidnight.fileURL).hasSuffix("- 00:00Z early\n"))
    }

    // MARK: - Inbox

    func testInboxTargetAppendsToInboxNote() throws {
        let inboxURL = root.appendingPathComponent("000 Inbox.md")
        let before = try contents(of: inboxURL)

        let outcome = try InstantCapture.capture(
            "inbox thought",
            target: .inbox,
            in: vault,
            now: utcDate("2026-08-07T08:15:00Z")
        )

        XCTAssertEqual(outcome.fileURL, inboxURL)
        XCTAssertEqual(outcome.target, .inbox)
        XCTAssertFalse(outcome.fellBackToDaily)
        XCTAssertEqual(try contents(of: inboxURL), before + "- 08:15Z inbox thought\n")
    }

    func testInboxTieBreakWritesLexicographicallyFirstNote() throws {
        let first = root.appendingPathComponent("000 Aardvark.md")
        try Data("# Second inbox\n".utf8).write(to: first)

        let outcome = try InstantCapture.capture(
            "tie",
            target: .inbox,
            in: vault,
            now: utcDate("2026-08-07T09:00:00Z")
        )

        XCTAssertEqual(outcome.fileURL, first)
        XCTAssertEqual(try contents(of: first), "# Second inbox\n- 09:00Z tie\n")
    }

    func testInboxCaptureIgnoresDirectoryShadowingTheInboxNote() throws {
        // Sorts before "000 Inbox.md"; must not win the tie-break or EISDIR
        // the append.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("000 Aardvark.md", isDirectory: true),
            withIntermediateDirectories: false
        )
        let inboxURL = root.appendingPathComponent("000 Inbox.md")
        let before = try contents(of: inboxURL)

        let outcome = try InstantCapture.capture(
            "shadowed",
            target: .inbox,
            in: vault,
            now: utcDate("2026-08-07T10:00:00Z")
        )

        XCTAssertEqual(outcome.fileURL, inboxURL)
        XCTAssertEqual(outcome.target, .inbox)
        XCTAssertFalse(outcome.fellBackToDaily)
        XCTAssertEqual(try contents(of: inboxURL), before + "- 10:00Z shadowed\n")
    }

    func testInboxCaptureFallsBackToDailyWhenOnlyADirectoryMatchesTheGlob() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("000 Inbox.md"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("000 Archive.md", isDirectory: true),
            withIntermediateDirectories: false
        )

        let outcome = try InstantCapture.capture(
            "no real inbox",
            target: .inbox,
            in: vault,
            now: utcDate("2026-08-07T10:30:00Z")
        )

        XCTAssertEqual(outcome.fileURL, root.appendingPathComponent("daily/2026-08-07.md"))
        XCTAssertEqual(outcome.target, .daily)
        XCTAssertTrue(outcome.fellBackToDaily)
        XCTAssertTrue(try contents(of: outcome.fileURL).hasSuffix("- 10:30Z no real inbox\n"))
    }

    func testMissingInboxFallsBackToDailyAndSaysSo() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("000 Inbox.md"))

        let outcome = try InstantCapture.capture(
            "homeless thought",
            target: .inbox,
            in: vault,
            now: utcDate("2026-08-07T09:30:00Z")
        )

        XCTAssertEqual(outcome.fileURL, root.appendingPathComponent("daily/2026-08-07.md"))
        XCTAssertEqual(outcome.target, .daily)
        XCTAssertTrue(outcome.fellBackToDaily)
        XCTAssertTrue(try contents(of: outcome.fileURL).hasSuffix("- 09:30Z homeless thought\n"))
    }

    // MARK: - Unicode byte-exactness

    func testUnicodeTextRoundTripsByteExact() throws {
        let text = "🦩 emoji · 中文字 · مرحبا بالعالم · שלום עולם"
        let noteURL = root.appendingPathComponent("daily/2026-08-07.md")
        let beforeData = try Data(contentsOf: noteURL)

        _ = try InstantCapture.capture(
            text,
            target: .daily,
            in: vault,
            now: utcDate("2026-08-07T12:00:00Z")
        )

        let afterData = try Data(contentsOf: noteURL)
        XCTAssertEqual(afterData, beforeData + Data("- 12:00Z \(text)\n".utf8))
    }

    // MARK: - Trailing-newline repair

    func testInsertsNewlineWhenFileDoesNotEndWithOne() throws {
        let noteURL = root.appendingPathComponent("daily/2026-08-07.md")
        try Data("# 2026-08-07\n- 09:00Z old".utf8).write(to: noteURL)

        _ = try InstantCapture.capture(
            "new",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-07T12:00:00Z")
        )

        XCTAssertEqual(
            try contents(of: noteURL),
            "# 2026-08-07\n- 09:00Z old\n- 12:00Z new\n"
        )
    }

    func testEmptyTextStillWritesATimestampedLine() throws {
        let noteURL = root.appendingPathComponent("daily/2026-08-07.md")
        let before = try contents(of: noteURL)

        _ = try InstantCapture.capture(
            "",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-07T12:00:00Z")
        )

        XCTAssertEqual(try contents(of: noteURL), before + "- 12:00Z \n")
    }

    // MARK: - Line breaks collapse to single spaces (one entry line, always)

    func testLineBreaksInTextEachBecomeASingleSpace() throws {
        let noteURL = root.appendingPathComponent("daily/2026-08-07.md")
        let before = try contents(of: noteURL)

        // LF, CRLF (one grapheme → one space), and bare CR.
        _ = try InstantCapture.capture(
            "line one\nline two\r\nline three\rend",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-07T12:00:00Z")
        )

        XCTAssertEqual(
            try contents(of: noteURL),
            before + "- 12:00Z line one line two line three end\n"
        )
    }

    func testConsecutiveAndTrailingLineBreaksAreNotCollapsedTogether() throws {
        let noteURL = root.appendingPathComponent("daily/2026-08-07.md")
        let before = try contents(of: noteURL)

        _ = try InstantCapture.capture(
            "a\n\nb\n",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-07T12:00:00Z")
        )

        // Two LFs → two spaces; the trailing LF → a trailing space. The
        // entry's own terminator is still exactly one \n.
        XCTAssertEqual(try contents(of: noteURL), before + "- 12:00Z a  b \n")
    }

    func testMultiLineMarkdownPasteCannotRestructureTheNote() throws {
        let noteURL = root.appendingPathComponent("daily/2026-08-07.md")

        _ = try InstantCapture.capture(
            "note to self\n# heading\n- fake entry",
            target: .daily,
            in: vault,
            now: utcDate("2026-08-07T12:00:00Z")
        )

        XCTAssertTrue(
            try contents(of: noteURL).hasSuffix("- 12:00Z note to self # heading - fake entry\n"),
            "pasted markdown must stay inside the single timestamped list line"
        )
    }

    // MARK: - Seeding never truncates (creation race with an external writer)

    func testSeedDailyNoteLeavesAnExistingFileUntouched() throws {
        // The race branch: another vault writer (register's UI, a sync
        // client) created the note between capture()'s existence check and
        // the seed write. Their content must survive.
        let now = utcDate("2026-08-09T08:00:00Z")
        let noteURL = vault.dailyNoteURL(on: now)
        try Data("external writer content\n".utf8).write(to: noteURL)

        XCTAssertNoThrow(try InstantCapture.seedDailyNote(at: noteURL, in: vault, now: now))

        XCTAssertEqual(try contents(of: noteURL), "external writer content\n")
    }
}
