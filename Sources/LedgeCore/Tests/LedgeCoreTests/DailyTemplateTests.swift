@testable import LedgeCore
import XCTest

/// Filling a daily template when Ledge seeds a new note (§5).
///
/// Human QA (2026-08-17): Ledge substituted only `{{date}}`, but register's
/// shipped template marks its frontmatter with the bare word `TEMPLATE`. With
/// register closed there was nothing to repair the note afterwards, so Ledge
/// wrote `id: TEMPLATE` to disk and it stayed there.
final class DailyTemplateTests: XCTestCase {
    private let now = utcDate("2026-08-17T11:26:00Z")

    /// The template shipped in the QA vault, verbatim.
    private let registerTemplate = """
    ---
    id: TEMPLATE
    title: TEMPLATE
    created: TEMPLATE
    modified: TEMPLATE
    tags: [daily]
    ---
    ## Log

    ## Tasks

    """

    private func filled() -> String {
        InstantCapture.fillingPlaceholders(in: registerTemplate, now: now)
    }

    // MARK: - The bug

    func testNoPlaceholderSurvives() {
        XCTAssertFalse(filled().contains("TEMPLATE"), filled())
    }

    func testTitleAndCreatedGetTheUTCDay() {
        let result = filled()
        XCTAssertTrue(result.contains("title: 2026-08-17"), result)
        XCTAssertTrue(result.contains("created: 2026-08-17"), result)
    }

    func testModifiedGetsAFullTimestamp() {
        XCTAssertTrue(filled().contains("modified: 2026-08-17T11:26:00Z"), filled())
    }

    /// `id:` must be a real minted ULID, not the day — the same rule the agent
    /// path follows, and for the same reason.
    func testIDGetsAMintedULID() throws {
        let line = try XCTUnwrap(
            filled().components(separatedBy: "\n").first { $0.hasPrefix("id:") }
        )
        let id = String(line.dropFirst("id:".count)).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(id.count, 26)
        XCTAssertTrue(id.allSatisfy(Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ").contains), id)
        XCTAssertEqual(String(id.prefix(10)), String(ULID.timeCharacters(for: now)))
    }

    func testTwoSeededNotesDoNotShareAnID() {
        XCTAssertNotEqual(filled(), InstantCapture.fillingPlaceholders(
            in: registerTemplate, now: now
        ))
    }

    func testBodyStructureIsUntouched() {
        XCTAssertTrue(filled().hasSuffix("## Log\n\n## Tasks\n"), filled())
    }

    // MARK: - The explicit placeholder style still works

    func testDoubleBraceDateStillSubstitutes() {
        XCTAssertEqual(
            InstantCapture.fillingPlaceholders(in: "# {{date}}\n", now: now),
            "# 2026-08-17\n"
        )
    }

    func testDoubleBraceTimeAndULID() {
        let result = InstantCapture.fillingPlaceholders(
            in: "time: {{time}}\nid: {{ulid}}\n", now: now
        )
        XCTAssertTrue(result.contains("time: 11:26Z"), result)
        XCTAssertFalse(result.contains("{{ulid}}"), result)
    }

    // MARK: - Leaving alone what is not a placeholder

    /// Only a whole-value `TEMPLATE` is a placeholder. Prose that merely
    /// mentions the word must survive.
    func testTemplateAsPartOfAValueIsNotSubstituted() {
        let input = "title: TEMPLATE NOTES\nbody: this is a TEMPLATE for meetings\n"
        XCTAssertEqual(InstantCapture.fillingPlaceholders(in: input, now: now), input)
    }

    func testLinesWithoutAColonAreUntouched() {
        let input = "TEMPLATE\n## Log\n- an entry\n"
        XCTAssertEqual(InstantCapture.fillingPlaceholders(in: input, now: now), input)
    }

    func testAnUnknownKeyFallsBackToTheDay() {
        XCTAssertEqual(
            InstantCapture.fillingPlaceholders(in: "reviewed: TEMPLATE\n", now: now),
            "reviewed: 2026-08-17\n"
        )
    }

    func testATemplateWithNoPlaceholdersIsReturnedUnchanged() {
        let input = "---\nid: 01K2Q5T8YXM6ZVN9C3H4J7RSPQ\n---\n## Log\n"
        XCTAssertEqual(InstantCapture.fillingPlaceholders(in: input, now: now), input)
    }
}
