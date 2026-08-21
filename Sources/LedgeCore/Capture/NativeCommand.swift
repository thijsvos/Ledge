// Ledge's own native slash commands — what the capture field's "/" typeahead
// lists and what a bare "/name" submit executes INSIDE Ledge (no capture
// written, no agent run spawned). Pure identity only: LedgeCore stays
// AppKit-free, so the enum carries names, summaries, and matching — the App
// layer injects the behaviors (see CaptureCoordinator.NativeCommandActions).
//
// Anything that is NOT an exact native match keeps its pre-existing meaning:
// the §5 router is untouched, and a typed Claude custom command ("/vet …")
// still reaches the CLI as a command via the invisible slash-restoration
// plumbing (SlashCommandCatalog.restoringCommandSlash).

import Foundation

/// One native Ledge command.
///
/// DECLARATION ORDER IS PRESENTATION ORDER (documented choice: CaseIterable
/// declaration order, not alphabetical): the suggestion list shows the
/// commands exactly as declared here, most-useful-first — help and the two
/// setup commands, then the vault/agent verbs, quit last.
public enum NativeCommand: String, CaseIterable, Sendable {
    case help
    case settings
    case checks
    case vault
    case resume
    case cancel
    case changes
    case undo
    case quit

    /// The command name WITHOUT the leading slash (the raw value).
    public var name: String {
        rawValue
    }

    /// One-liner for the suggestion-list row.
    public var summary: String {
        switch self {
        case .help: "Show what you can type here"
        case .settings: "Open Ledge settings"
        case .checks: "Run the setup checks"
        case .vault: "Reveal the vault in Finder"
        case .resume: "Resume a recent agent session in Terminal"
        case .cancel: "Cancel the running agent run (and queued ones)"
        case .changes: "Show what the last agent run changed"
        case .undo: "Undo the last agent run's changes"
        case .quit: "Quit Ledge"
        }
    }

    /// The exact-match rule: fires ONLY when the whole trimmed input is
    /// exactly "/" + name — case-sensitive, no arguments. "/cancel now" is
    /// NOT native and flows to Claude like any other `/` prompt; "/Cancel",
    /// "/cancelx", and a slash-less "cancel" never match. Whitespace is
    /// trimmed first so typeahead completion's "/cancel " (trailing space)
    /// executes natively.
    public static func match(input: String) -> NativeCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return NativeCommand(rawValue: String(trimmed.dropFirst()))
    }

    /// Case-insensitive name-prefix filter preserving declaration order (all
    /// names are lowercase ASCII, so lowercasing the needle suffices). The
    /// empty prefix matches everything — the bare "/" lists every command.
    public static func matching(prefix: String) -> [NativeCommand] {
        guard !prefix.isEmpty else { return allCases }
        let needle = prefix.lowercased()
        return allCases.filter { $0.name.hasPrefix(needle) }
    }
}

/// What one submitted capture-field input DOES — the App layer's submit
/// precedence, extracted pure so LedgeCore tests pin it: a native match wins
/// BEFORE the §5 router ever sees the input; everything else routes exactly
/// as before (`CaptureRouter` is untouched).
///
/// Shadowing (the full picture, not just exact-name collisions): a native
/// name shadows an identically named Claude custom command for bare "/name"
/// submits, AND — via the typeahead's single-match Enter auto-complete
/// (`SlashSuggestionModel.shouldCompleteOnReturn`) — a Claude command whose
/// full name is a proper prefix of exactly one native name is also shadowed
/// for bare Enter: "/ca" + Enter runs /cancel even if the user has a Claude
/// command named "ca". The highlighted row renders under that same condition,
/// so the shadowing is always visible before Enter; the shadowed Claude
/// command stays reachable by ending the token ("/ca " + Enter, or any
/// arguments) — a space hides the list and the input flows to Claude with
/// its slash restored. "/name args" is never native and flows to Claude.
public enum SubmitAction: Equatable, Sendable {
    case native(NativeCommand)
    case routed(CaptureRoute)

    public static func decide(_ input: String) -> SubmitAction {
        if let command = NativeCommand.match(input: input) {
            return .native(command)
        }
        return .routed(CaptureRouter.route(input))
    }
}
