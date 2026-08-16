// Capture routing (§5 of the architecture doc). Pure classification of the
// capture field's input — no I/O, no state, exhaustively unit-tested.

import Foundation

/// Where an instant capture lands (§5).
public enum InstantTarget: Equatable, Sendable {
    /// `vault/daily/YYYY-MM-DD.md` (UTC date, register's convention).
    case daily
    /// The note whose filename begins with `000` at the vault root.
    case inbox
}

/// What one submitted capture-field input means.
public enum CaptureRoute: Equatable, Sendable {
    /// Input started with `/` — the prompt is everything after the slash,
    /// untrimmed, so a bare `"/"` yields an empty prompt. The App layer hands
    /// it to `ClaudeRunner`, restoring the leading slash first when the first
    /// token names a known Claude command (see
    /// `SlashCommandCatalog.restoringCommandSlash`).
    case agent(prompt: String)
    /// Anything else — Ledge appends the text itself. Zero AI, zero tokens.
    case instant(target: InstantTarget, text: String)
}

/// The §5 routing rules, literally:
///
/// * starts with `/`     → `.agent(prompt:)`, prompt = everything after the
///   slash, no trimming (`"/"` → empty prompt);
/// * starts with `".i "` → `.instant(.inbox, text:)`, text = everything after
///   the 3-character prefix, no trimming (`".i  x"` → `" x"`);
/// * anything else (including bare `".i"` and the empty string) →
///   `.instant(.daily, text: input)`.
///
/// Prefix matching is case-sensitive and exact — `" /x"` and `".I x"` are
/// plain daily text.
public enum CaptureRouter {
    private static let agentPrefix = "/"
    private static let inboxPrefix = ".i "

    public static func route(_ input: String) -> CaptureRoute {
        if input.hasPrefix(agentPrefix) {
            return .agent(prompt: String(input.dropFirst()))
        }
        if input.hasPrefix(inboxPrefix) {
            return .instant(target: .inbox, text: String(input.dropFirst(inboxPrefix.count)))
        }
        return .instant(target: .daily, text: input)
    }
}
