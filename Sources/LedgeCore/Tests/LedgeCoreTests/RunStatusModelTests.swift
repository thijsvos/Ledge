@testable import LedgeCore
import XCTest

/// RunStatusModel: the hover chip's run bookkeeping (set/clear paths, the
/// Enter-time start date surviving the runner's confirmation) and the pure
/// prompt-excerpt helper (budget, Character-boundary cut, newline collapse).
@MainActor
final class RunStatusModelTests: XCTestCase {
    // MARK: - Excerpt (pure helper)

    func testExcerptShortPromptUnchanged() {
        XCTAssertEqual(RunStatusModel.excerpt(of: "summarize inbox"), "summarize inbox")
    }

    func testExcerptExactlyAtBudgetUnchanged() {
        let prompt = String(repeating: "a", count: RunStatusModel.excerptMaxLength)
        XCTAssertEqual(RunStatusModel.excerpt(of: prompt), prompt)
    }

    func testExcerptOverBudgetCutAndEllipsized() {
        let prompt = String(repeating: "a", count: RunStatusModel.excerptMaxLength + 30)
        let excerpt = RunStatusModel.excerpt(of: prompt)
        XCTAssertEqual(
            excerpt,
            String(repeating: "a", count: RunStatusModel.excerptMaxLength) + "…"
        )
        XCTAssertEqual(excerpt.count, RunStatusModel.excerptMaxLength + 1)
    }

    /// Multi-scalar graphemes (family emoji = 7 unicode scalars each) must
    /// never split: the cut counts Characters, not scalars or UTF-16 units.
    func testExcerptCutsOnCharacterBoundary() {
        let family = "👨‍👩‍👧‍👦"
        let prompt = String(repeating: family, count: 60)
        let excerpt = RunStatusModel.excerpt(of: prompt)
        XCTAssertEqual(
            excerpt,
            String(repeating: family, count: RunStatusModel.excerptMaxLength) + "…"
        )
    }

    func testExcerptCollapsesNewlinesAndTrims() {
        XCTAssertEqual(
            RunStatusModel.excerpt(of: "  first line\nsecond line\r\nthird  "),
            "first line second line third"
        )
    }

    func testExcerptEmptyAndWhitespaceOnly() {
        XCTAssertEqual(RunStatusModel.excerpt(of: ""), "")
        XCTAssertEqual(RunStatusModel.excerpt(of: "   \n  "), "")
    }

    func testExcerptCustomMaxLength() {
        XCTAssertEqual(RunStatusModel.excerpt(of: "abcdef", maxLength: 3), "abc…")
    }

    // MARK: - Run bookkeeping (set/clear paths)

    func testInitialStateIsIdle() {
        let model = RunStatusModel()
        XCTAssertNil(model.liveRunPrompt)
        XCTAssertNil(model.runStartDate)
        XCTAssertFalse(model.isHoveringWhileRunning)
        XCTAssertEqual(model.promptExcerpt, "")
    }

    func testRecordRunStartSetsPromptAndDate() {
        let model = RunStatusModel()
        let enter = Date(timeIntervalSinceReferenceDate: 1000)
        model.recordRunStart(prompt: "summarize inbox", startDate: enter)
        XCTAssertEqual(model.liveRunPrompt, "summarize inbox")
        XCTAssertEqual(model.runStartDate, enter)
    }

    /// The runner's runStarted confirmation (same prompt, seconds later)
    /// must not shift the Enter-time zero point — elapsed time stays honest.
    func testSamePromptConfirmationKeepsEnterStartDate() {
        let model = RunStatusModel()
        let enter = Date(timeIntervalSinceReferenceDate: 1000)
        let confirmed = enter.addingTimeInterval(4)
        model.recordRunStart(prompt: "summarize inbox", startDate: enter)
        model.recordRunStart(prompt: "summarize inbox", startDate: confirmed)
        XCTAssertEqual(model.runStartDate, enter)
    }

    /// A queued run starting (different prompt) restarts the clock.
    func testDifferentPromptRestartsClock() {
        let model = RunStatusModel()
        let first = Date(timeIntervalSinceReferenceDate: 1000)
        let second = first.addingTimeInterval(30)
        model.recordRunStart(prompt: "first", startDate: first)
        model.recordRunStart(prompt: "second", startDate: second)
        XCTAssertEqual(model.liveRunPrompt, "second")
        XCTAssertEqual(model.runStartDate, second)
    }

    /// Same prompt submitted again after the previous run completed (clear):
    /// a fresh clock, not the stale one.
    func testRecordAfterClearSetsFreshDate() {
        let model = RunStatusModel()
        let first = Date(timeIntervalSinceReferenceDate: 1000)
        let second = first.addingTimeInterval(60)
        model.recordRunStart(prompt: "same", startDate: first)
        model.clear()
        model.recordRunStart(prompt: "same", startDate: second)
        XCTAssertEqual(model.runStartDate, second)
    }

    func testClearClearsRunButNotHoverFlag() {
        let model = RunStatusModel()
        model.recordRunStart(prompt: "summarize inbox")
        model.isHoveringWhileRunning = true
        model.clear()
        XCTAssertNil(model.liveRunPrompt)
        XCTAssertNil(model.runStartDate)
        XCTAssertEqual(model.promptExcerpt, "")
        // The hover flag belongs to the window controller (cleared on
        // pointer exit / state change), never to the run bookkeeping.
        XCTAssertTrue(model.isHoveringWhileRunning)
    }

    func testPromptExcerptUsesSharedBudget() {
        let model = RunStatusModel()
        let prompt = String(repeating: "b", count: RunStatusModel.excerptMaxLength + 10)
        model.recordRunStart(prompt: prompt)
        XCTAssertEqual(model.promptExcerpt, RunStatusModel.excerpt(of: prompt))
    }
}
