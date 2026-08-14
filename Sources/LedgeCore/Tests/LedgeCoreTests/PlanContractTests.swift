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
            .append(path: "daily/2026-08-14.md", text: "- 09:15Z Something\n"),
            .create(path: "notes/new-thing.md", content: "# New thing\n"),
            .replace(path: "notes/index.md", find: "exact existing text", with: "replacement"),
        ])
    }
}
