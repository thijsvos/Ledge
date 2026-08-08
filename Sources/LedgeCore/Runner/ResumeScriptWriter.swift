// §6 escape hatch: "Open in Terminal" writes /tmp/ledge-resume-<uuid>.command
// containing `cd '<vault>' && claude --resume '<sessionID>'` and opens it via
// NSWorkspace (App layer) — Terminal runs .command files through the user's
// login shell, so a version-managed `claude` (fnm, …) is on PATH there.

import Foundation

public enum ResumeScriptError: Error, Equatable, Sendable, LocalizedError {
    /// Session IDs are interpolated into a shell script; anything outside
    /// `^[A-Za-z0-9-]+$` is refused outright (shell-injection guard).
    case invalidSessionID(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSessionID(id):
            "Invalid session ID: \(id)"
        }
    }
}

public enum ResumeScriptWriter {
    /// The one-liner both the script and "Copy command" share:
    /// `cd '<vault>' && claude --resume '<sessionID>'`. Embedded single quotes
    /// in the vault path are escaped ('\''); the session ID must match
    /// `^[A-Za-z0-9-]+$` or this throws.
    public static func commandLine(vaultPath: String, sessionID: String) throws -> String {
        guard isValidSessionID(sessionID) else {
            throw ResumeScriptError.invalidSessionID(sessionID)
        }
        let escapedVault = vaultPath.replacingOccurrences(of: "'", with: "'\\''")
        return "cd '\(escapedVault)' && claude --resume '\(sessionID)'"
    }

    /// Writes `ledge-resume-<uuid>.command` (0755) into `directory` (default
    /// /tmp per §6 — a Terminal-visible path matching the doc) and returns its
    /// URL. Throws on an invalid session ID or write failure.
    @discardableResult
    public static func writeResumeScript(
        vaultPath: String,
        sessionID: String,
        directory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    ) throws -> URL {
        let line = try commandLine(vaultPath: vaultPath, sessionID: sessionID)
        let url = directory.appendingPathComponent(
            "ledge-resume-\(UUID().uuidString).command",
            isDirectory: false
        )
        try Data((line + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    /// `^[A-Za-z0-9-]+$`, ASCII only.
    static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) // 0-9
                || (0x41 ... 0x5A).contains(byte) // A-Z
                || (0x61 ... 0x7A).contains(byte) // a-z
                || byte == 0x2D // -
        }
    }
}
