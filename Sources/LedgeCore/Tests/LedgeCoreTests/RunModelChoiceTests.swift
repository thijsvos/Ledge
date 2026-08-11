@testable import LedgeCore
import XCTest

/// RunModelChoice (the ⌘↩ per-run model selection): the pure `effectiveModel`
/// resolver — the exact value the spawn site hands the pinned argv builder —
/// the resulting argv for all three choices, and the enqueue → PendingRun
/// pass-through. A full fake-claude lifecycle test is deliberately absent:
/// the resolver matrix plus the pass-through assertion pin the whole path.
final class RunModelChoiceTests: XCTestCase {
    // MARK: - Resolver truth table

    func testEffectiveModelTruthTable() {
        // .configured → the Settings model (nil when none set).
        XCTAssertEqual(
            RunModelChoice.effectiveModel(choice: .configured, configured: "sonnet"), "sonnet"
        )
        XCTAssertNil(RunModelChoice.effectiveModel(choice: .configured, configured: nil))
        // .cliDefault → NO flag, even when a Settings model exists.
        XCTAssertNil(RunModelChoice.effectiveModel(choice: .cliDefault, configured: "sonnet"))
        XCTAssertNil(RunModelChoice.effectiveModel(choice: .cliDefault, configured: nil))
        // .named → the sanitized one-off name, overriding the Settings model.
        XCTAssertEqual(
            RunModelChoice.effectiveModel(choice: .named("opus"), configured: "sonnet"), "opus"
        )
        XCTAssertEqual(
            RunModelChoice.effectiveModel(choice: .named("  opus\n"), configured: nil), "opus"
        )
    }

    /// A one-off name the sanitizer drops (empty, whitespace, flag-like)
    /// falls back to `.configured` — never to an accidental widening.
    func testNamedSanitizedToNilFallsBackToConfigured() {
        XCTAssertEqual(
            RunModelChoice.effectiveModel(choice: .named(""), configured: "sonnet"), "sonnet"
        )
        XCTAssertEqual(
            RunModelChoice.effectiveModel(choice: .named("   "), configured: "sonnet"), "sonnet"
        )
        XCTAssertEqual(
            RunModelChoice.effectiveModel(choice: .named("--model"), configured: "sonnet"), "sonnet"
        )
        XCTAssertNil(RunModelChoice.effectiveModel(choice: .named("-x"), configured: nil))
    }

    // MARK: - argv matrix (through the EXISTING pinned builder)

    func testArgvMatrixForAllThreeChoices() {
        func argv(_ choice: RunModelChoice, configured: String?) -> [String] {
            ClaudeRunner.arguments(
                prompt: "p",
                resumeSessionID: nil,
                model: RunModelChoice.effectiveModel(choice: choice, configured: configured),
                effort: "high"
            )
        }
        let base = ClaudeRunner.arguments(prompt: "p", resumeSessionID: nil)
        // .configured → --model <settings model>; effort untouched.
        XCTAssertEqual(
            argv(.configured, configured: "sonnet"),
            base + ["--model", "sonnet", "--effort", "high"]
        )
        // .cliDefault → NO --model at all, even with a configured model —
        // the user's own Claude Code default does the work.
        XCTAssertEqual(argv(.cliDefault, configured: "sonnet"), base + ["--effort", "high"])
        // .named → --model <one-off>.
        XCTAssertEqual(
            argv(.named("opus"), configured: "sonnet"),
            base + ["--model", "opus", "--effort", "high"]
        )
        // Sanitize-fallback: an unusable one-off behaves exactly as .configured.
        XCTAssertEqual(argv(.named("  "), configured: "sonnet"), argv(.configured, configured: "sonnet"))
    }

    // MARK: - PendingRun pass-through

    /// Queued runs must carry their choice to the spawn site; the default is
    /// `.configured` (pre-chooser behavior).
    func testEnqueueCarriesModelChoiceIntoPendingRun() async throws {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment["FAKE_CLAUDE_MODE"] = "slow"
        environment["FAKE_CLAUDE_SLEEP"] = "2"
        let runner = try ClaudeRunner(configuration: ClaudeRunner.Configuration(
            binaryURL: Fixtures.fakeClaude,
            vault: Vault(root: Fixtures.vault),
            environment: environment
        ))
        guard case .started = await runner.enqueue(prompt: "live") else {
            await runner.terminateAll()
            return XCTFail("first submit must start")
        }
        _ = await runner.enqueue(prompt: "queued-named", modelChoice: .named("opus"))
        _ = await runner.enqueue(prompt: "queued-default") // .configured by default
        _ = await runner.enqueue(prompt: "queued-cli", modelChoice: .cliDefault)
        let choices = await runner.pendingModelChoicesForTesting()
        XCTAssertEqual(choices, [.named("opus"), .configured, .cliDefault])
        await runner.terminateAll()
    }
}
