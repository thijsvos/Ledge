// InstantCapture (§5): appends one line to the daily note or the inbox note,
// synchronously, well inside the 50 ms Enter→file-on-disk budget. Open-write-
// close append; no FSEvents, no watchers, nothing after the write — register's
// own watcher repaints its UI within 100 ms.

import Foundation
import os

/// The result of one instant capture.
public struct CaptureOutcome: Equatable, Sendable {
    /// The file the entry was appended to.
    public let fileURL: URL
    /// The target actually written. Differs from the requested target only
    /// after an inbox→daily fallback.
    public let target: InstantTarget
    /// True when `.inbox` was requested but no `000*.md` note exists, so the
    /// entry landed in the daily note instead — the peek must say so (§5).
    public let fellBackToDaily: Bool

    public init(fileURL: URL, target: InstantTarget, fellBackToDaily: Bool) {
        self.fileURL = fileURL
        self.target = target
        self.fellBackToDaily = fellBackToDaily
    }
}

/// Performs one instant capture. All dates and times are UTC (register's
/// convention); text passes through byte-exact as UTF-8 with one deliberate
/// exception: each Unicode line break (CRLF counts as one) becomes a single
/// space, so the entry is always exactly one markdown list line — a
/// multi-line paste must never inject raw un-timestamped markdown into the
/// note.
public enum InstantCapture {
    /// Synchronously appends `- HH:MMZ <text>\n` to the resolved target.
    ///
    /// * `.daily` → `vault/daily/YYYY-MM-DD.md`; if missing, the parent
    ///   directory is created as needed and the file is seeded from
    ///   `vault/templates/daily.md` (every literal `{{date}}` replaced with
    ///   `YYYY-MM-DD`) when that template exists, else with `# YYYY-MM-DD\n`.
    /// * `.inbox` → the `000*.md` note at the vault root; if absent, falls
    ///   back to the daily note and reports `fellBackToDaily`.
    /// * Line breaks in `text` each collapse to a single space (see above).
    ///
    /// If the existing file does not end in a newline, one is inserted first
    /// so the entry starts on its own line. The repair newline and the entry
    /// are written in a single write call (atomic in the §5 sense).
    public static func capture(
        _ text: String,
        target: InstantTarget,
        in vault: Vault,
        now: Date = Date()
    ) throws -> CaptureOutcome {
        let entryText = oneLine(text)
        var resolved = resolve(target: target, in: vault, now: now)
        if !FileManager.default.fileExists(atPath: resolved.url.path) {
            if resolved.target == .inbox {
                // The inbox note vanished between the glob in inboxURL() and
                // this check — external processes write this vault too (§1).
                // Treat it as the missing-inbox fallback rather than seeding
                // a daily-template file at the inbox path.
                resolved = (vault.dailyNoteURL(on: now), .daily, true)
            }
            if !FileManager.default.fileExists(atPath: resolved.url.path) {
                try seedDailyNote(at: resolved.url, in: vault, now: now)
            }
        }
        let entryBytes = try appendEntry(entryText, to: resolved.url, now: now)
        Logger(subsystem: "app.ledge", category: "capture").info(
            "instant capture: \(entryBytes) bytes → \(resolved.url.lastPathComponent, privacy: .public) (target \(resolved.target == .inbox ? "inbox" : "daily", privacy: .public), fellBack \(resolved.fellBack))"
        )
        return CaptureOutcome(
            fileURL: resolved.url,
            target: resolved.target,
            fellBackToDaily: resolved.fellBack
        )
    }

    // MARK: - Target resolution

    private static func resolve(
        target: InstantTarget, in vault: Vault, now: Date
    ) -> (url: URL, target: InstantTarget, fellBack: Bool) {
        switch target {
        case .daily:
            return (vault.dailyNoteURL(on: now), .daily, false)
        case .inbox:
            if let inbox = vault.inboxURL() {
                return (inbox, .inbox, false)
            }
            return (vault.dailyNoteURL(on: now), .daily, true)
        }
    }

    // MARK: - One-line normalization

    /// Replaces each Unicode line break in `text` (CRLF is one `Character`,
    /// so one replacement) with a single space. Everything else passes
    /// through byte-exact — this is the only transformation instant capture
    /// ever applies to the user's text.
    private static func oneLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return String(text.map { $0.isNewline ? " " : $0 })
    }

    // MARK: - Daily note creation

    /// Creates `vault/daily/` if needed and seeds the note: template contents
    /// with `{{date}}` substituted when the template exists, else a minimal
    /// `# YYYY-MM-DD\n` header.
    ///
    /// Never truncates: the write is `.withoutOverwriting`, so losing the
    /// creation race to an external writer (register's UI, a sync client —
    /// §1: they write this vault concurrently) leaves their content intact
    /// and the caller's append still lands. Internal (not `private`) so the
    /// no-truncation guarantee is directly testable — the race branch is not
    /// reachable deterministically through `capture`.
    static func seedDailyNote(at url: URL, in vault: Vault, now: Date) throws {
        let day = Vault.dayStamp(on: now)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed: String
        if FileManager.default.fileExists(atPath: vault.templatesDailyURL.path) {
            let template = try String(contentsOf: vault.templatesDailyURL, encoding: .utf8)
            seed = template.replacingOccurrences(of: "{{date}}", with: day)
        } else {
            seed = "# \(day)\n"
        }
        do {
            try Data(seed.utf8).write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Lost the creation race: the other writer's content wins.
        }
    }

    // MARK: - Append

    /// Appends exactly `- HH:MMZ <text>\n` (UTC, zero-padded), preceded by a
    /// repair `\n` when the file's last byte is not a newline. One open, one
    /// write, one close. Returns the number of bytes written.
    private static func appendEntry(_ text: String, to url: URL, now: Date) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        var needsLeadingNewline = false
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)
            needsLeadingNewline = lastByte != Data([0x0A])
        }

        var entry = Data()
        if needsLeadingNewline {
            entry.append(0x0A)
        }
        entry.append(contentsOf: "- \(Vault.timeStamp(on: now))Z \(text)\n".utf8)

        try handle.seekToEnd()
        try handle.write(contentsOf: entry)
        return entry.count
    }
}
