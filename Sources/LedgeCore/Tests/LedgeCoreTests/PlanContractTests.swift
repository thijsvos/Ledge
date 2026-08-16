@testable import LedgeCore
import XCTest

/// What Ledge asks the agent for (§2.3). The contract travels in the prompt,
/// so these guard the two ways it can fail silently: swallowing the user's
/// request, and drifting out of step with the decoder that reads the reply.
final class PlanContractTests: XCTestCase {
    private let now = utcDate("2026-08-14T09:15:00Z")

    func testUsersRequestComesLastAndIntact() {
        let wrapped = PlanContract.wrap(prompt: "log the kickoff meeting", now: now)
        XCTAssertTrue(wrapped.hasSuffix("log the kickoff meeting"))
    }

    func testMultiLinePromptSurvivesIntact() {
        let prompt = "first line\nsecond line"
        XCTAssertTrue(PlanContract.wrap(prompt: prompt, now: now).hasSuffix(prompt))
    }

    // MARK: - The injected date

    /// register dates everything in UTC. A CLI injects its own *local* date,
    /// which names the wrong daily note for anyone west of UTC after 00:00Z —
    /// so Ledge states the UTC day itself.
    func testInjectsTheUTCDayStamp() {
        XCTAssertTrue(PlanContract.wrap(prompt: "x", now: now).contains("2026-08-14"))
    }

    func testDateFlipsAtUTCMidnightNotLocalMidnight() {
        let before = PlanContract.wrap(prompt: "x", now: utcDate("2026-08-14T23:59:59Z"))
        let after = PlanContract.wrap(prompt: "x", now: utcDate("2026-08-15T00:00:01Z"))
        XCTAssertTrue(before.contains("2026-08-14"))
        XCTAssertTrue(after.contains("2026-08-15"))
    }

    func testDateMatchesVaultDayStamp() {
        XCTAssertTrue(PlanContract.wrap(prompt: "x", now: now).contains(Vault.dayStamp(on: now)))
    }

    // MARK: - The injected time

    /// A CLI injects a date but never a clock, so an agent asked to stamp a log
    /// entry copies whatever the worked example shows. Human QA caught exactly
    /// that: every filed entry came back "00:00Z". Ledge states the time.
    func testInjectsTheUTCTimeStamp() {
        let wrapped = PlanContract.wrap(prompt: "x", now: utcDate("2026-08-16T21:40:00Z"))
        XCTAssertTrue(wrapped.contains("21:40Z"), "contract must state the current UTC time")
    }

    func testTimeMatchesVaultTimeStamp() {
        let stamp = Vault.timeStamp(on: now)
        XCTAssertTrue(PlanContract.wrap(prompt: "x", now: now).contains("\(stamp)Z"))
    }

    /// The example is what the agent imitates, so its timestamp must be the
    /// real one — a hardcoded example time is indistinguishable, to the model,
    /// from an instruction to use that time.
    func testTheWorkedExampleCarriesTheCurrentTimeNotAFixedOne() throws {
        let later = utcDate("2026-08-16T21:40:00Z")
        let plan = try EditPlanExtractor.extract(from: PlanContract.wrap(prompt: "x", now: later))
        XCTAssertEqual(
            plan.edits.first,
            .replace(
                path: "daily/2026-08-16.md",
                find: "## Log\n- 09:00Z An earlier entry",
                with: "## Log\n- 09:00Z An earlier entry\n- 21:40Z Something"
            )
        )
    }

    // MARK: - Filing into the right section

    /// Human QA: a log line filed into a daily note whose `## Log` sits above
    /// `## Tasks` landed under Tasks, because `append` writes to the end of the
    /// file and the worked example demonstrated appending to that very note.
    /// The example must lead with `replace` so the agent imitates the right move.
    func testTheWorkedExampleLeadsWithReplaceOnTheDailyNote() throws {
        let plan = try EditPlanExtractor.extract(from: PlanContract.wrap(prompt: "x", now: now))
        guard case let .replace(path, _, _) = plan.edits.first else {
            return XCTFail("the daily-note example must be a replace, not an append")
        }
        XCTAssertEqual(path, "daily/\(Vault.dayStamp(on: now)).md")
    }

    /// `append` is still demonstrated — but on a FLAT note, where the end of the
    /// file genuinely is the right place.
    func testAppendIsDemonstratedOnlyOnAFlatNote() throws {
        let plan = try EditPlanExtractor.extract(from: PlanContract.wrap(prompt: "x", now: now))
        let appends = plan.edits.filter {
            if case .append = $0 {
                true
            } else {
                false
            }
        }
        XCTAssertEqual(appends.count, 1)
        XCTAssertFalse(
            appends[0].path.hasPrefix("daily/"),
            "appending to the daily note is what put an entry under the wrong heading"
        )
    }

    func testContractWarnsThatAppendGoesToTheEnd() {
        let wrapped = PlanContract.wrap(prompt: "x", now: now)
        XCTAssertTrue(wrapped.contains("very END of the file"))
        XCTAssertTrue(wrapped.contains("To file under a heading, use \"replace\""))
    }

    /// The stamp Ledge asks the agent for and the stamp Ledge writes itself for
    /// a plain capture must be the same shape, or a day's log reads as two
    /// different formats depending on how each line got there.
    func testAgentStampShapeMatchesInstantCapture() {
        XCTAssertTrue(PlanContract.wrap(prompt: "x", now: now).contains("- HH:MMZ text"))
        XCTAssertEqual(Vault.timeStamp(on: now).count, 5)
    }

    // MARK: - Contract and decoder agree

    func testEveryOperationIsNamed() {
        let wrapped = PlanContract.wrap(prompt: "x", now: now)
        for op in ["create", "append", "replace"] {
            XCTAssertTrue(wrapped.contains("\"\(op)\""), "contract should show \(op)")
        }
    }

    func testContractStatesThereIsNoDelete() {
        XCTAssertTrue(PlanContract.wrap(prompt: "x", now: now).contains("no delete operation"))
    }

    func testContractGivesTheEmptyPlanEscapeHatch() {
        XCTAssertTrue(PlanContract.wrap(prompt: "x", now: now).contains(#"{"edits": []}"#))
    }

    /// The worked example in the contract must be something our own decoder
    /// accepts. If the two ever drift apart, every run fails and the reason
    /// is invisible — so pin them together.
    func testTheWorkedExampleActuallyDecodes() throws {
        let plan = try EditPlanExtractor.extract(from: PlanContract.wrap(prompt: "x", now: now))
        XCTAssertEqual(plan.edits, [
            .replace(
                path: "daily/2026-08-14.md",
                find: "## Log\n- 09:00Z An earlier entry",
                with: "## Log\n- 09:00Z An earlier entry\n- 09:15Z Something"
            ),
            .create(path: "notes/new-thing.md", content: "# New thing\n"),
            .append(path: "notes/a-flat-note.md", text: "- 09:15Z Something\n"),
        ])
    }
}
