@testable import LedgeCore
import XCTest

/// §6 binary resolution: override wins, probe order, cached login-shell
/// fallback (called exactly once per resolver), none found. All I/O injected.
final class ClaudeBinaryResolverTests: XCTestCase {
    func testOverrideWinsWhenExecutable() {
        var checked: [String] = []
        let resolver = ClaudeBinaryResolver(
            overridePath: "/custom/claude",
            isExecutable: { path in
                checked.append(path)
                return path == "/custom/claude"
            },
            shellLookup: {
                XCTFail("shell lookup must not run when the override resolves")
                return nil
            },
            home: "/Users/test"
        )
        XCTAssertEqual(resolver.resolve(), "/custom/claude")
        XCTAssertEqual(checked, ["/custom/claude"], "probes must not run when the override resolves")
    }

    func testOverrideExpandsTilde() {
        let resolver = ClaudeBinaryResolver(
            overridePath: "~/bin/claude",
            isExecutable: { $0 == "/Users/test/bin/claude" },
            shellLookup: { nil },
            home: "/Users/test"
        )
        XCTAssertEqual(resolver.resolve(), "/Users/test/bin/claude")
    }

    func testNonExecutableOverrideFallsThroughToProbes() {
        let resolver = ClaudeBinaryResolver(
            overridePath: "/broken/claude",
            isExecutable: { $0 == "/opt/homebrew/bin/claude" },
            shellLookup: { nil },
            home: "/Users/test"
        )
        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/claude")
    }

    /// Probes run in the §6 order, tilde expanded against the injected home.
    func testProbeOrderAndTildeExpansion() {
        var checked: [String] = []
        let resolver = ClaudeBinaryResolver(
            isExecutable: { path in
                checked.append(path)
                return path == "/Users/test/.local/bin/claude"
            },
            shellLookup: { nil },
            home: "/Users/test"
        )
        XCTAssertEqual(resolver.resolve(), "/Users/test/.local/bin/claude")
        XCTAssertEqual(checked, [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Users/test/.local/bin/claude",
        ], "probe order per §6, stopping at the first hit")
    }

    func testAllFourProbeLocationsAreTried() {
        var checked: [String] = []
        let resolver = ClaudeBinaryResolver(
            isExecutable: { path in
                checked.append(path)
                return false
            },
            shellLookup: { nil },
            home: "/Users/test"
        )
        XCTAssertNil(resolver.resolve())
        XCTAssertEqual(checked, [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Users/test/.local/bin/claude",
            "/Users/test/.claude/local/claude",
        ])
    }

    /// (c) is cached: two resolves, one shell lookup (the fnm case — on this
    /// machine the login shell is the production path that matters).
    func testShellFallbackIsCached() {
        var lookups = 0
        let resolver = ClaudeBinaryResolver(
            isExecutable: { _ in false },
            shellLookup: {
                lookups += 1
                return "/via/login-shell/claude"
            },
            home: "/Users/test"
        )
        XCTAssertEqual(resolver.resolve(), "/via/login-shell/claude")
        XCTAssertEqual(resolver.resolve(), "/via/login-shell/claude")
        XCTAssertEqual(lookups, 1, "login-shell lookup runs once per launch")
    }

    func testNothingFoundReturnsNilAndCachesTheMiss() {
        var lookups = 0
        let resolver = ClaudeBinaryResolver(
            isExecutable: { _ in false },
            shellLookup: {
                lookups += 1
                return nil
            },
            home: "/Users/test"
        )
        XCTAssertNil(resolver.resolve())
        XCTAssertNil(resolver.resolve())
        XCTAssertEqual(lookups, 1, "a failed lookup is cached too")
    }

    // MARK: - Login-shell process hygiene (real /bin/zsh, never the real claude)

    /// §2.2 / CLAUDE.md hard rule: EVERY process Ledge spawns is
    /// ANTHROPIC_API_KEY-free — including the login-shell lookup. The zsh
    /// child reports what it sees; dotfiles may prefix noise, so only the
    /// suffix is asserted.
    func testLoginShellLookupStripsAPIKeyFromChildEnvironment() {
        let result = ClaudeBinaryResolver.loginShellLookup(
            command: "printf '%s' \"CLEAN-${ANTHROPIC_API_KEY-unset}\"",
            environment: ["ANTHROPIC_API_KEY": "sk-test-leaked-from-shell"]
        )
        XCTAssertEqual(
            result?.hasSuffix("CLEAN-unset"), true,
            "ANTHROPIC_API_KEY leaked into the login-shell child: \(result ?? "nil")"
        )
    }

    /// The rest of the environment passes through untouched.
    func testLoginShellLookupKeepsOtherVariables() {
        let result = ClaudeBinaryResolver.loginShellLookup(
            command: "printf '%s' \"VALUE-${LEDGE_TEST_CANARY-unset}\"",
            environment: ["LEDGE_TEST_CANARY": "survives"]
        )
        XCTAssertEqual(result?.hasSuffix("VALUE-survives"), true)
    }

    /// A hung dotfile (or command) must never wedge a submit: the zsh child is
    /// SIGKILLed at the timeout and the lookup returns nil promptly.
    func testLoginShellLookupTimesOutAndKillsHungShell() {
        let started = Date()
        let result = ClaudeBinaryResolver.loginShellLookup(
            command: "sleep 30",
            environment: ProcessInfo.processInfo.environment,
            timeout: 0.5
        )
        XCTAssertNil(result)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 5,
            "hung shell must be SIGKILLed at the timeout, not waited on"
        )
    }
}
