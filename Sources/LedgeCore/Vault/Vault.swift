// Vault path validation and helpers (§5). LedgeCore imports Foundation only;
// the App layer supplies the root path (the §7 Settings vault picker writes
// UserDefaults "vaultPath" — see CaptureCoordinator). No global state, so a
// vault is never validated against a root someone else has since changed.

import Foundation
import os

/// Typed validation failures for a vault root.
public enum VaultError: Error, Equatable, Sendable, LocalizedError {
    case rootDoesNotExist(path: String)
    case rootIsNotADirectory(path: String)
    /// §2.5: the agent's cwd is never `/`.
    case rootIsFilesystemRoot
    /// §2.5: the agent's cwd is never `~`.
    case rootIsHomeDirectory(path: String)

    public var errorDescription: String? {
        switch self {
        case let .rootDoesNotExist(path):
            "Vault folder does not exist: \(path)"
        case let .rootIsNotADirectory(path):
            "Vault path is not a folder: \(path)"
        case .rootIsFilesystemRoot:
            "Refusing to use the filesystem root as the vault"
        case let .rootIsHomeDirectory(path):
            "Refusing to use the home folder as the vault: \(path)"
        }
    }
}

/// A validated register vault root. Construction proves the path exists and is
/// a directory; helpers derive the well-known locations Ledge writes to.
public struct Vault: Equatable, Sendable {
    /// The root exactly as it was handed in — NOT standardized and NOT
    /// symlink-resolved. `init` resolves a copy to run its §2.5 checks and
    /// never writes the result back, so this stays the folder the user
    /// actually chose: it becomes the child's cwd and the value the App layer
    /// compares runners by. Consequence: equality is path equality, so `/tmp`
    /// and `/private/tmp` are different vaults, and comparing this against an
    /// already-resolved path will not match.
    public let root: URL

    /// Validating init: `root` must exist, be a directory, and be neither the
    /// filesystem root nor the home folder (§2.5 — an unattended run's cwd is
    /// never `/` and never `~`). Every refusal is a typed `VaultError` whose
    /// `errorDescription` the peeks and Settings show verbatim.
    public init(root: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            Logger(subsystem: "app.ledge", category: "vault")
                .error("vault root does not exist: \(root.path, privacy: .public)")
            throw VaultError.rootDoesNotExist(path: root.path)
        }
        guard isDirectory.boolValue else {
            Logger(subsystem: "app.ledge", category: "vault")
                .error("vault root is not a directory: \(root.path, privacy: .public)")
            throw VaultError.rootIsNotADirectory(path: root.path)
        }
        // §2.5 (safety): an unattended run must never have cwd `/` or the
        // user's home folder — refuse both outright. The agent is read-only
        // now and Ledge does the writing, but the fence outlived the flag:
        // cwd is what Read/Glob/Grep range over, and every edit-plan path
        // resolves against it. Symlinks are resolved first so a link to the
        // home directory cannot sneak past.
        let resolvedPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolvedPath != "/" else {
            Logger(subsystem: "app.ledge", category: "vault")
                .error("vault root refused: filesystem root (§2.5)")
            throw VaultError.rootIsFilesystemRoot
        }
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard resolvedPath != homePath else {
            Logger(subsystem: "app.ledge", category: "vault")
                .error("vault root refused: home directory (§2.5)")
            throw VaultError.rootIsHomeDirectory(path: root.path)
        }
        self.root = root
    }

    // MARK: - Well-known locations

    /// `vault/daily/YYYY-MM-DD.md` for `date`'s UTC calendar day.
    public func dailyNoteURL(on date: Date) -> URL {
        root.appendingPathComponent("daily", isDirectory: true)
            .appendingPathComponent("\(Self.dayStamp(on: date)).md", isDirectory: false)
    }

    /// `vault/templates/daily.md`. May not exist — callers check.
    public var templatesDailyURL: URL {
        root.appendingPathComponent("templates", isDirectory: true)
            .appendingPathComponent("daily.md", isDirectory: false)
    }

    /// The inbox note: glob `000*.md` at the vault ROOT only (non-recursive,
    /// case-sensitive), lexicographically first filename on a tie. Regular
    /// files only — a directory named e.g. `000 Archive.md` must neither win
    /// the tie-break nor masquerade as the inbox (appending to it would fail
    /// with EISDIR). Nil when no such note exists (InstantCapture then falls
    /// back to the daily note).
    public func inboxURL() -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return nil
        }
        return names
            .filter { name in
                guard name.hasPrefix("000"), name.hasSuffix(".md") else { return false }
                var isDirectory: ObjCBool = false
                let path = root.appendingPathComponent(name).path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
            .sorted(by: <)
            .first
            .map { root.appendingPathComponent($0, isDirectory: false) }
    }

    // MARK: - UTC stamps (register's convention: all dates/times UTC)

    /// `YYYY-MM-DD` for the UTC calendar day of `date`. Never uses
    /// `Calendar.current` — a gregorian calendar pinned to GMT, so the user's
    /// locale/zone can never leak into filenames.
    public static func dayStamp(on date: Date) -> String {
        let components = utcComponents(of: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
    }

    /// `HH:MM` UTC, zero-padded.
    public static func timeStamp(on date: Date) -> String {
        let components = utcComponents(of: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static func utcComponents(of date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}
