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

    /// Writes exactly one `- HH:MMZ <text>` line (UTC, zero-padded) into the
    /// note, under `## Log` when the note has one. Returns the bytes added.
    ///
    /// A note built from a register daily template ends with `## Tasks`, so the
    /// original end-of-file append filed every captured thought as a task —
    /// human QA hit this on the very first capture. Where a heading exists the
    /// entry belongs under it, which is the same rule `PlanContract` gives the
    /// agent; a note with no `## Log` still appends at the end, byte for byte
    /// as before.
    ///
    /// This is now read-modify-write rather than a bare append, so it goes out
    /// atomically (write-then-rename): another writer (§1) can lose an
    /// interleaved edit, but never sees a half-written note.
    private static func appendEntry(_ text: String, to url: URL, now: Date) throws -> Int {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let entry = "- \(Vault.timeStamp(on: now))Z \(text)"
        let updated = inserting(entry, into: existing)
        try Data(updated.utf8).write(to: url, options: .atomic)
        return max(0, updated.utf8.count - existing.utf8.count)
    }

    /// Pure so the placement rule is testable without touching a disk.
    ///
    /// `entry` carries no trailing newline. The insertion point is the end of
    /// the `## Log` section — just before the next `##` heading, backing up over
    /// blank lines so the entry sits directly beneath the last one rather than
    /// after the gap. With no `## Log`, appends at the end and repairs a missing
    /// final newline, exactly as the pre-QA behaviour did.
    static func inserting(_ entry: String, into contents: String) -> String {
        var lines = contents.components(separatedBy: "\n")

        guard let logIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "## log"
        }) else {
            var result = contents
            if !result.isEmpty, !result.hasSuffix("\n") {
                result += "\n"
            }
            return result + entry + "\n"
        }

        var insertAt = lines.count
        if let next = lines[(logIndex + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("##")
        }) {
            insertAt = next
        }
        while insertAt > logIndex + 1,
              lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty
        {
            insertAt -= 1
        }
        lines.insert(entry, at: insertAt)
        return lines.joined(separator: "\n")
    }
}
