@testable import LedgeCore
import XCTest

/// Where a captured entry lands inside the note (§5).
///
/// Human QA (2026-08-17) caught the first capture into a fresh daily note built
/// from a register template landing under `## Tasks`: the template ends with
/// that heading and the old code appended at end-of-file, so every thought was
/// filed as a task. These pin the placement rule and, just as importantly, that
/// a note without a log section still behaves exactly as it used to.
final class CaptureSectionTests: XCTestCase {
    private let entry = "- 10:59Z testing instant capture"

    /// The exact template shipped in the QA vault.
    private let registerTemplate = """
    ---
    id: TEMPLATE
    title: TEMPLATE
    tags: [daily]
    ---
    ## Log

    ## Tasks

    """

    // MARK: - The bug

    func testEntryLandsUnderLogNotAtEndOfFile() {
        let result = InstantCapture.inserting(entry, into: registerTemplate)
        XCTAssertEqual(result, """
        ---
        id: TEMPLATE
        title: TEMPLATE
        tags: [daily]
        ---
        ## Log
        \(entry)

        ## Tasks

        """)
    }

    func testEntryDoesNotLandUnderTasks() throws {
        let result = InstantCapture.inserting(entry, into: registerTemplate)
        let logIndex = try XCTUnwrap(result.range(of: "## Log")?.lowerBound)
        let tasksIndex = try XCTUnwrap(result.range(of: "## Tasks")?.lowerBound)
        let entryIndex = try XCTUnwrap(result.range(of: entry)?.lowerBound)
        XCTAssertTrue(logIndex < entryIndex && entryIndex < tasksIndex)
    }

    /// Successive captures stack in order under the heading rather than
    /// reversing or scattering.
    func testSecondEntryGoesBeneathTheFirst() {
        let once = InstantCapture.inserting("- 09:00Z first", into: registerTemplate)
        let twice = InstantCapture.inserting("- 10:00Z second", into: once)
        XCTAssertTrue(twice.contains("## Log\n- 09:00Z first\n- 10:00Z second\n"), twice)
    }

    // MARK: - Shapes of the log section

    func testLogSectionAtEndOfFileWithNoFollowingHeading() {
        let contents = "# Day\n\n## Log\n- 09:00Z earlier\n"
        XCTAssertEqual(
            InstantCapture.inserting(entry, into: contents),
            "# Day\n\n## Log\n- 09:00Z earlier\n\(entry)\n"
        )
    }

    func testEmptyLogSection() {
        XCTAssertEqual(
            InstantCapture.inserting(entry, into: "## Log\n\n## Tasks\n"),
            "## Log\n\(entry)\n\n## Tasks\n"
        )
    }

    func testHeadingMatchIsCaseInsensitiveAndIgnoresTrailingSpace() {
        for heading in ["## Log", "## log", "## LOG", "## Log   "] {
            let result = InstantCapture.inserting(entry, into: "\(heading)\n\n## Tasks\n")
            XCTAssertTrue(result.contains("\(heading)\n\(entry)"), heading)
        }
    }

    /// A deeper heading still ends the section — `### Detail` under `## Log`
    /// means the log's own lines have finished.
    func testAnyFollowingHeadingEndsTheSection() {
        let result = InstantCapture.inserting(entry, into: "## Log\n- 09:00Z a\n### Detail\nx\n")
        XCTAssertTrue(result.contains("- 09:00Z a\n\(entry)\n### Detail"), result)
    }

    // MARK: - No log section: unchanged from before the fix

    func testWithoutALogSectionItStillAppendsAtTheEnd() {
        XCTAssertEqual(
            InstantCapture.inserting(entry, into: "# 2026-08-17\n"),
            "# 2026-08-17\n\(entry)\n"
        )
    }

    func testMissingFinalNewlineIsStillRepaired() {
        XCTAssertEqual(
            InstantCapture.inserting(entry, into: "# 2026-08-17"),
            "# 2026-08-17\n\(entry)\n"
        )
    }

    func testEmptyFileGetsJustTheEntry() {
        XCTAssertEqual(InstantCapture.inserting(entry, into: ""), "\(entry)\n")
    }

    /// "## Logbook" is not the log section — a prefix match would file entries
    /// into the wrong heading.
    func testASimilarlyNamedHeadingIsNotTheLogSection() {
        let result = InstantCapture.inserting(entry, into: "## Logbook\n\n## Tasks\n")
        XCTAssertTrue(result.hasSuffix("## Tasks\n\(entry)\n"), result)
    }
}
