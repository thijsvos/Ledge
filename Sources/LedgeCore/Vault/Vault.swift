// Vault path validation and helpers (§5). LedgeCore imports Foundation only;
// the App layer supplies the root path (UserDefaults key "vaultPath" until the
// Settings UI arrives in Phase 4 — see CaptureCoordinator). No global state.

import Foundation
import os

/// Typed validation failures for a vault root.
public enum VaultError: Error, Equatable, Sendable, LocalizedError {
    case rootDoesNotExist(path: String)
    case rootIsNotADirectory(path: String)

    public var errorDescription: String? {
        switch self {
        case let .rootDoesNotExist(path):
            "Vault folder does not exist: \(path)"
        case let .rootIsNotADirectory(path):
            "Vault path is not a folder: \(path)"
        }
    }
}

/// A validated register vault root. Construction proves the path exists and is
/// a directory; helpers derive the well-known locations Ledge writes to.
public struct Vault: Equatable, Sendable {
    public let root: URL

    /// Validating init: `root` must exist and be a directory (§2.5 — refuse to
    /// operate on a vault path that isn't a real folder).
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
