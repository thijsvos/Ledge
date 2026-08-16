// §7 "continue last session" selection logic, extracted pure so the App layer
// stays a thin shell. The stored ID must pass the same `^[A-Za-z0-9-]+$` guard
// `ResumeScriptWriter` enforces before it is ever interpolated anywhere; an
// invalid stored value is treated as nil AND flagged for clearing.

import Foundation

public enum ResumePolicy {
    /// The outcome of `pickResumeSessionID`. `shouldClearStored` is true only
    /// when the stored value exists but is invalid — the caller then removes
    /// it from UserDefaults so it can never be considered again.
    public struct Choice: Equatable, Sendable {
        public let sessionID: String?
        public let shouldClearStored: Bool

        public init(sessionID: String?, shouldClearStored: Bool) {
            self.sessionID = sessionID
            self.shouldClearStored = shouldClearStored
        }
    }

    /// Decides whether a `/` run resumes the vault's last session. `enabled`
    /// is the §7 "Continue last session for / runs" toggle (UserDefaults
    /// "continueLastSession", default false); `stored` is the persisted
    /// "lastSessionID:<vault>" value.
    ///
    /// A nil `sessionID` means a fresh session — the §6 default. The toggle
    /// gates everything: while it is off the stored value is ignored entirely
    /// and never cleared, so turning it back on still finds the old session.
    public static func pickResumeSessionID(enabled: Bool, stored: String?) -> Choice {
        guard enabled else {
            return Choice(sessionID: nil, shouldClearStored: false)
        }
        guard let stored, !stored.isEmpty else {
            return Choice(sessionID: nil, shouldClearStored: false)
        }
        guard ResumeScriptWriter.isValidSessionID(stored) else {
            return Choice(sessionID: nil, shouldClearStored: true)
        }
        return Choice(sessionID: stored, shouldClearStored: false)
    }
}
