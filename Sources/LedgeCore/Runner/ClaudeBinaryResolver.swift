// §6 binary resolution. GUI apps do NOT inherit shell PATH (classic failure),
// so: explicit override → well-known locations → one cached login-shell
// lookup (`/bin/zsh -lc 'command -v claude'` — on machines where claude lives
// behind a version manager like fnm, this is the path that matters) → nil,
// which the UI surfaces as "Claude Code not found" (full onboarding is
// Phase 4). Never bundles or downloads the CLI.

import Foundation
import os

/// `@unchecked Sendable`: the one piece of mutable state (`cachedShellResult`)
/// is guarded by `lock`, and the injected closures are only required to be
/// individually thread-safe (the production defaults are). Sendable so the App
/// layer can run `resolve()` OFF the main actor — the login-shell fallback
/// spawns `/bin/zsh -lc` and must never block the UI.
public final class ClaudeBinaryResolver: @unchecked Sendable {
    /// Probe order for well-known install locations (`~` expanded against the
    /// real home). Note: probing ~/.claude/local/claude looks for the BINARY
    /// the official installer places there — nothing auth-related is ever
    /// touched (§2.1).
    static let probePaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.local/bin/claude",
        "~/.claude/local/claude",
    ]

    private let overridePath: String?
    private let isExecutable: (String) -> Bool
    private let shellLookup: () -> String?
    private let home: String
    /// `.none` = not attempted yet; `.some(nil)` = attempted, nothing found.
    /// The lookup runs at most once per resolver (== once per launch when the
    /// App layer keeps one resolver alive), success or failure.
    private var cachedShellResult: String??
    /// Serializes `resolve()`: concurrent submits must not race the cache or
    /// run two login shells.
    private let lock = NSLock()
    private let logger = Logger(subsystem: "app.ledge", category: "runner")

    /// - Parameters:
    ///   - overridePath: the Settings override (Phase 4 UI; plumbed now).
    ///   - isExecutable: injectable for tests; defaults to FileManager.
    ///   - shellLookup: injectable for tests; defaults to the login-shell
    ///     `command -v claude` probe.
    ///   - home: injectable for tests; tilde paths expand against this.
    public init(
        overridePath: String? = nil,
        isExecutable: @escaping (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        shellLookup: @escaping () -> String? = ClaudeBinaryResolver.loginShellLookup,
        home: String = NSHomeDirectory()
    ) {
        self.overridePath = overridePath
        self.isExecutable = isExecutable
        self.shellLookup = shellLookup
        self.home = home
    }

    /// Resolution order per §6: (a) override if set AND executable, (b) probe
    /// well-known paths in order, (c) cached login-shell lookup, (d) nil.
    /// Thread-safe; call it off the main actor — (c) runs a login shell.
    public func resolve() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let overridePath, !overridePath.isEmpty {
            let expanded = expandTilde(overridePath)
            if isExecutable(expanded) {
                return expanded
            }
            logger.info("claude override not executable, falling through: \(expanded, privacy: .public)")
        }
        for path in Self.probePaths {
            let expanded = expandTilde(path)
            if isExecutable(expanded) {
                return expanded
            }
        }
        if let cached = cachedShellResult {
            return cached
        }
        let found = shellLookup()
        cachedShellResult = .some(found)
        if let found {
            logger.info("claude found via login shell: \(found, privacy: .public)")
        } else {
            logger.error("claude binary not found (override, probes, and login shell all failed)")
        }
        return found
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return home + path.dropFirst()
    }

    /// Default (c): `/bin/zsh -lc 'command -v claude'`. A login shell so the
    /// user's version manager (fnm, nvm, …) initializes PATH. Runs once per
    /// launch and is cached by `resolve()`; production-only (tests inject).
    public static func loginShellLookup() -> String? {
        loginShellLookup(
            command: "command -v claude",
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Internal seam (tests inject the command and a polluted environment).
    /// Two hard properties: the zsh child gets the SANITIZED environment —
    /// every process Ledge spawns is ANTHROPIC_API_KEY-free (§2.2, CLAUDE.md
    /// hard rule), login-shell dotfiles included — and the child is SIGKILLed
    /// after `timeout`, so a hung dotfile can never wedge a submit.
    static func loginShellLookup(
        command: String,
        environment: [String: String],
        timeout: TimeInterval = 5
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice
        process.environment = RunEnvironment.sanitizedEnvironment(environment)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
