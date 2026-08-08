@testable import LedgeCore
import XCTest

/// §7 "continue last session" selection: the toggle gates everything, and a
/// stored ID must pass the ResumeScriptWriter `^[A-Za-z0-9-]+$` guard before
/// it is ever used — invalid stored values are treated as nil AND flagged for
/// clearing.
final class ResumePolicyTests: XCTestCase {
    func testDisabledIgnoresStoredValue() {
        let choice = ResumePolicy.pickResumeSessionID(enabled: false, stored: "abc-123")
        XCTAssertNil(choice.sessionID)
        XCTAssertFalse(choice.shouldClearStored, "toggle off must not clear a valid stored ID")
    }

    func testDisabledWithInvalidStoredStillDoesNotClear() {
        let choice = ResumePolicy.pickResumeSessionID(enabled: false, stored: "bad; rm -rf /")
        XCTAssertNil(choice.sessionID)
        XCTAssertFalse(choice.shouldClearStored, "disabled = the stored value is never inspected")
    }

    func testEnabledWithNothingStored() {
        let choice = ResumePolicy.pickResumeSessionID(enabled: true, stored: nil)
        XCTAssertNil(choice.sessionID)
        XCTAssertFalse(choice.shouldClearStored)
    }

    func testEnabledWithEmptyStoredTreatedAsUnset() {
        let choice = ResumePolicy.pickResumeSessionID(enabled: true, stored: "")
        XCTAssertNil(choice.sessionID)
        XCTAssertFalse(choice.shouldClearStored, "empty = unset, nothing to clear")
    }

    func testEnabledWithValidStoredResumes() {
        let id = "0198a2b4-79cb-7dd2-8a30-f2b8b0e14d4c"
        let choice = ResumePolicy.pickResumeSessionID(enabled: true, stored: id)
        XCTAssertEqual(choice.sessionID, id)
        XCTAssertFalse(choice.shouldClearStored)
    }

    /// Shell-injection guard: anything outside `^[A-Za-z0-9-]+$` is refused
    /// and flagged for clearing (§ decision: invalid stored = nil + clear).
    func testEnabledWithInvalidStoredIsNilAndCleared() {
        for bad in ["abc def", "abc$(touch /tmp/x)", "id'quote", "sessão", "a_b", "x;y"] {
            let choice = ResumePolicy.pickResumeSessionID(enabled: true, stored: bad)
            XCTAssertNil(choice.sessionID, "must reject: \(bad)")
            XCTAssertTrue(choice.shouldClearStored, "must clear: \(bad)")
        }
    }

    func testGuardMatchesResumeScriptWriterGuard() {
        // The same ID must be accepted by both gates — one regex, one policy.
        let id = "Abc-123-XYZ"
        XCTAssertNotNil(try? ResumeScriptWriter.commandLine(vaultPath: "/v", sessionID: id))
        XCTAssertEqual(
            ResumePolicy.pickResumeSessionID(enabled: true, stored: id).sessionID, id
        )
    }
}
