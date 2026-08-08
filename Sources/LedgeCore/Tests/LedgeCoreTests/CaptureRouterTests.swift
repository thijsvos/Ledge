@testable import LedgeCore
import XCTest

/// §5 router: every branch plus the edge cases pinned by the spec — "/", "/x",
/// ".i ", bare ".i", double-space after ".i ", empty string, unicode. The
/// router never trims.
final class CaptureRouterTests: XCTestCase {
    // MARK: - Agent branch

    func testSlashRoutesToAgentWithEverythingAfterTheSlash() {
        XCTAssertEqual(
            CaptureRouter.route("/plan tomorrow"),
            .agent(prompt: "plan tomorrow")
        )
    }

    func testBareSlashIsEmptyAgentPrompt() {
        XCTAssertEqual(CaptureRouter.route("/"), .agent(prompt: ""))
    }

    func testSlashSingleCharacter() {
        XCTAssertEqual(CaptureRouter.route("/x"), .agent(prompt: "x"))
    }

    func testAgentPromptIsNotTrimmed() {
        XCTAssertEqual(CaptureRouter.route("/  spaced  "), .agent(prompt: "  spaced  "))
    }

    func testSlashWinsOverInboxPrefix() {
        XCTAssertEqual(CaptureRouter.route("/.i x"), .agent(prompt: ".i x"))
    }

    // MARK: - Inbox branch

    func testInboxPrefixRoutesToInboxWithRestAfterThreeCharPrefix() {
        XCTAssertEqual(
            CaptureRouter.route(".i buy milk"),
            .instant(target: .inbox, text: "buy milk")
        )
    }

    func testInboxPrefixAloneYieldsEmptyText() {
        XCTAssertEqual(CaptureRouter.route(".i "), .instant(target: .inbox, text: ""))
    }

    func testInboxDoubleSpaceKeepsTheSecondSpace() {
        XCTAssertEqual(CaptureRouter.route(".i  x"), .instant(target: .inbox, text: " x"))
    }

    // MARK: - Daily branch (everything else)

    func testPlainTextGoesToDailyUnchanged() {
        XCTAssertEqual(
            CaptureRouter.route("remember the milk"),
            .instant(target: .daily, text: "remember the milk")
        )
    }

    func testBareDotIGoesToDailyAsLiteralText() {
        XCTAssertEqual(CaptureRouter.route(".i"), .instant(target: .daily, text: ".i"))
    }

    func testEmptyStringGoesToDaily() {
        XCTAssertEqual(CaptureRouter.route(""), .instant(target: .daily, text: ""))
    }

    func testLeadingWhitespaceDefeatsBothPrefixes() {
        XCTAssertEqual(CaptureRouter.route(" /x"), .instant(target: .daily, text: " /x"))
        XCTAssertEqual(CaptureRouter.route(" .i x"), .instant(target: .daily, text: " .i x"))
    }

    func testInboxPrefixIsCaseSensitive() {
        XCTAssertEqual(CaptureRouter.route(".I x"), .instant(target: .daily, text: ".I x"))
    }

    // MARK: - Unicode passes through untouched

    func testUnicodePassesThroughEveryBranch() {
        let mixed = "🎉 中文 مرحبا שלום"
        XCTAssertEqual(CaptureRouter.route("/\(mixed)"), .agent(prompt: mixed))
        XCTAssertEqual(CaptureRouter.route(".i \(mixed)"), .instant(target: .inbox, text: mixed))
        XCTAssertEqual(CaptureRouter.route(mixed), .instant(target: .daily, text: mixed))
    }

    // MARK: - Line breaks pass through untouched

    /// The one-line normalization (line break → space) is InstantCapture's
    /// decision, not the router's: agent prompts keep their line breaks.
    func testLineBreaksPassThroughEveryBranch() {
        XCTAssertEqual(CaptureRouter.route("/a\nb"), .agent(prompt: "a\nb"))
        XCTAssertEqual(CaptureRouter.route(".i a\nb"), .instant(target: .inbox, text: "a\nb"))
        XCTAssertEqual(CaptureRouter.route("a\nb"), .instant(target: .daily, text: "a\nb"))
    }
}
