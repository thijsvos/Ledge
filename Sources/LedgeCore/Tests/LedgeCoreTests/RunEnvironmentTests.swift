@testable import LedgeCore
import XCTest

/// §2.2: the child environment is the inherited environment with exactly
/// ANTHROPIC_API_KEY removed — nothing else touched. (The integration proof —
/// a polluted parent env never reaching a spawned child — lives in
/// ClaudeRunnerTests.testEnvironmentSanitizationIntegration.)
final class RunEnvironmentTests: XCTestCase {
    func testRemovesExactlyTheAPIKey() {
        let env = [
            "ANTHROPIC_API_KEY": "sk-test-must-die",
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/test",
            "ANTHROPIC_API_KEY_BACKUP": "left-alone-on-purpose",
            "FAKE_CLAUDE_MODE": "success",
        ]
        let sanitized = RunEnvironment.sanitizedEnvironment(env)
        XCTAssertNil(sanitized["ANTHROPIC_API_KEY"])
        var expected = env
        expected.removeValue(forKey: "ANTHROPIC_API_KEY")
        XCTAssertEqual(sanitized, expected, "only ANTHROPIC_API_KEY may be removed")
    }

    func testEnvironmentWithoutKeyIsUntouched() {
        let env = ["PATH": "/usr/bin", "TERM": "xterm-256color"]
        XCTAssertEqual(RunEnvironment.sanitizedEnvironment(env), env)
    }

    func testEmptyEnvironment() {
        XCTAssertEqual(RunEnvironment.sanitizedEnvironment([:]), [:])
    }
}
