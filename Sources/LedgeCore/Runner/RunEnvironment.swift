// §2.2 environment sanitization: the child process environment is the
// inherited environment with ANTHROPIC_API_KEY removed, so a key exported in
// the user's shell can never cause accidental API billing. The spawner
// (ClaudeRunner) MUST route every child environment through this function.

import Foundation

public enum RunEnvironment {
    /// The exact variable stripped from every child environment.
    public static let strippedKey = "ANTHROPIC_API_KEY"

    /// Returns `env` with exactly `ANTHROPIC_API_KEY` removed. Nothing else is
    /// touched (unit-test asserted).
    public static func sanitizedEnvironment(_ env: [String: String]) -> [String: String] {
        var sanitized = env
        sanitized.removeValue(forKey: strippedKey)
        return sanitized
    }
}
