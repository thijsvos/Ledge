import Foundation

/// App-layer UserDefaults keys (§7), in one place.
enum DefaultsKey {
    /// The vault folder path (Phase 2; Settings now owns the UI for it).
    static let vaultPath = CaptureCoordinator.vaultPathDefaultsKey
    /// The claude binary override; empty/absent = unset (resolver probes).
    static let claudeBinaryPath = "claudeBinaryPath"
    /// "Continue last session for / runs" toggle; default false (§7).
    static let continueLastSession = "continueLastSession"
    /// Optional `--model` for agent runs; empty/absent = the user's own
    /// Claude Code default.
    static let claudeModel = "claudeModel"
    /// `--effort` for agent runs. Absent = Ledge's default "high" (note-work
    /// doesn't need the user's heavier interactive default); the sentinel
    /// `effortCLIDefault` = pass no flag, use the CLI's own default.
    static let claudeEffort = "claudeEffort"
    /// Sentinel stored in `claudeEffort` meaning "no --effort flag".
    static let effortCLIDefault = "default"
    /// True once the user has finished (dismissed) first-launch onboarding.
    static let hasRunOnboarding = "hasRunOnboarding"

    /// The per-vault last-session-ID key (§6: "last session ID stored per
    /// vault in UserDefaults"). The ONLY constructor of this dynamic key —
    /// read and write sites must both use it, or a drift in the format would
    /// silently orphan every stored session ID.
    static func lastSessionID(vaultPath: String) -> String {
        "lastSessionID:\(vaultPath)"
    }
}
