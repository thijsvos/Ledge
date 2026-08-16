// Per-run model selection (backlog #14): the ⌘↩ chooser lets a SINGLE agent
// run use a heavier model while the Settings default stays the everyday
// choice. Pure identity + one pure resolver — the chooser UI state lives in
// ModelChoiceModel, the plumbing in ClaudeRunner.enqueue, and the resolver is
// what the spawn site feeds into the EXISTING
// `ClaudeRunner.arguments(prompt:resumeSessionID:model:effort:now:)` builder
// (the argv shape itself is untouched). Effort is deliberately NOT part of this:
// every choice leaves `Configuration.effort` exactly as configured.

import Foundation

/// Which model ONE enqueued run should use.
public enum RunModelChoice: Equatable, Sendable {
    /// Use `Configuration.model` — the Settings default. The pre-chooser
    /// behavior, and the default of every submit path.
    case configured
    /// Pass NO `--model` flag at all — the user's own Claude Code default
    /// does the work, even when a Settings model is configured.
    case cliDefault
    /// `--model <name>` for this one run. The name runs through the existing
    /// `sanitizeOverride` guard; a value sanitized to nil falls back to
    /// `.configured` (a bad one-off must never silently widen to the CLI
    /// default the user did not pick).
    case named(String)

    /// The `model:` value the spawn site hands the argv builder — nil means
    /// "no --model flag". `configured` is the runner's `Configuration.model`
    /// (itself sanitized again inside `arguments`, so double-sanitizing is
    /// harmless).
    public static func effectiveModel(choice: RunModelChoice, configured: String?) -> String? {
        switch choice {
        case .configured:
            configured
        case .cliDefault:
            nil
        case let .named(name):
            ClaudeRunner.sanitizeOverride(name) ?? configured
        }
    }
}
