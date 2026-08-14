// Taking a run back (§2.3).
//
// The applier has to read every file it touches before touching it, so it is
// holding the "before" version anyway. Keeping it costs nothing and buys two
// things: rollback when a plan fails halfway through, and the `/undo` command.
//
// The record is deliberately plain data — no vault, no run, no dependency on
// anything still being alive — so it survives the run that produced it.

import Foundation
import os

/// Everything needed to put a vault back the way it was before one run.
public struct RunUndoRecord: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let url: URL
        /// Contents before the run; nil means the run created this file, so
        /// undoing removes it.
        public let before: String?

        public init(url: URL, before: String?) {
            self.url = url
            self.before = before
        }
    }

    /// One entry per distinct file, in first-touched order. When a plan edits
    /// the same file twice, the entry holds the state before the *first* edit
    /// — undo returns to the start of the run, not to a midpoint.
    public private(set) var entries: [Entry] = []
    /// Folders the run created, deepest last, so undo can remove them in
    /// reverse once their contents are gone.
    public private(set) var createdDirectories: [URL] = []

    public init() {}

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var fileCount: Int {
        entries.count
    }

    /// First touch wins — later edits to the same file must not overwrite the
    /// original pre-image.
    public mutating func record(url: URL, before: String?) {
        guard !entries.contains(where: { $0.url == url }) else { return }
        entries.append(Entry(url: url, before: before))
    }

    public mutating func recordCreatedDirectory(_ url: URL) {
        guard !createdDirectories.contains(url) else { return }
        createdDirectories.append(url)
    }
}

public enum RunUndo {
    /// Restores every entry. Files the run created are removed; files it
    /// changed are written back byte for byte.
    ///
    /// Best-effort by design: one unrestorable file must not strand the rest,
    /// so failures are logged and the remaining entries still run. Returns the
    /// number of files actually put back.
    @discardableResult
    public static func restore(_ record: RunUndoRecord) -> Int {
        let logger = Logger(subsystem: "app.ledge", category: "runner")
        var restored = 0

        for entry in record.entries {
            do {
                if let before = entry.before {
                    try Data(before.utf8).write(to: entry.url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: entry.url.path) {
                    try FileManager.default.removeItem(at: entry.url)
                }
                restored += 1
            } catch {
                logger.error(
                    "undo failed for \(entry.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Deepest first, and only when empty — a folder the user has since put
        // something else into stays.
        for directory in record.createdDirectories.reversed() {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            if contents?.isEmpty == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        return restored
    }
}
