// Local run-history for the /resume picker: one JSON line per finished (or
// cancelled) agent run, appended to a file the APP layer owns — LedgeCore
// never hardcodes the location. §2 discipline: the history lives ONLY in
// Ledge's own Application Support directory (never the vault, never
// ~/.claude), is written event-driven (append on completion, read on
// /resume — no timers, no polling), and never leaves the machine.
//
// `RunHistoryStore` is deliberately NOT an actor: it is a value type with
// explicit synchronous I/O, called from the App layer OFF the main actor
// (Task.detached, exactly like the slash-command catalog scan). An actor
// would only add hops: the APP LAYER serializes all history I/O instead —
// every append is a link on one chained task (file order therefore provably
// equals completion order, which is what `recentRuns`' newest-first-by-file-
// order relies on), and the /resume read awaits that chain, so it can never
// overtake a just-recorded completion. That same serialization is what makes
// `compactIfNeeded`'s read-then-atomic-replace safe: compaction only ever
// runs inside `append`, and no other append can be in flight. O_APPEND
// whole-line writes remain as defense in depth, and the reader tolerates
// anything torn or foreign anyway.

import Foundation
import os

// MARK: - Record

/// One recorded agent run — everything the /resume picker shows plus enough
/// context to debug a failure later. Codable via synthesis; unknown future
/// fields in the file are ignored on decode, and a record a future Ledge
/// wrote with an unknown `outcome` case fails to decode and is skipped by
/// `recentRuns` (never fatal).
public struct RunRecord: Codable, Equatable, Sendable {
    /// How the run ended. Synthesized Codable (SE-0295) — encoded as
    /// `{"success":{}}`, `{"failure":{"reason":"…"}}`, `{"cancelled":{}}`.
    public enum Outcome: Codable, Equatable, Sendable {
        case success
        case failure(reason: String)
        case cancelled
    }

    /// `resultExcerpt` is capped at this many characters by the initializer —
    /// the history is a picker source, not a transcript store.
    public static let maxResultExcerptLength = 500

    public var id: UUID
    public var date: Date
    public var vaultPath: String
    public var prompt: String
    /// The CLI session ID when the stream carried one — what /resume hands to
    /// the resume-script machinery. Still validated by `ResumeScriptWriter`
    /// before it is ever interpolated anywhere (the picker model filters on
    /// exactly that validity).
    public var sessionID: String?
    /// The effective `--model` value the run's argv carried; nil when no
    /// --model flag was passed (the user's own Claude Code default did the
    /// work). Additive field — synthesized Codable decodes it with
    /// `decodeIfPresent`, so pre-field JSONL lines still decode (tested).
    public var model: String?
    public var outcome: Outcome
    /// The vault files LEDGE wrote (`AppliedPlan.filesChanged`), not what the
    /// agent proposed: a refused plan changed nothing and records nothing, and
    /// so does a cancelled run. The /resume picker renders "N files" from this,
    /// so filling it from the stream's like-named `RunSummary.editedFiles`
    /// would show nothing forever (§2.3).
    public var editedFiles: [String]
    public var durationMS: Int?
    /// Result text truncated to `maxResultExcerptLength` characters.
    public var resultExcerpt: String?
    public var stderrTail: [String]

    public init(
        id: UUID,
        date: Date,
        vaultPath: String,
        prompt: String,
        sessionID: String?,
        model: String? = nil,
        outcome: Outcome,
        editedFiles: [String],
        durationMS: Int?,
        resultExcerpt: String?,
        stderrTail: [String]
    ) {
        self.id = id
        self.date = date
        self.vaultPath = vaultPath
        self.prompt = prompt
        self.sessionID = sessionID
        self.model = model
        self.outcome = outcome
        self.editedFiles = editedFiles
        self.durationMS = durationMS
        self.resultExcerpt = resultExcerpt.map { String($0.prefix(Self.maxResultExcerptLength)) }
        self.stderrTail = stderrTail
    }
}

// MARK: - Store

public enum RunHistoryError: Error, Equatable, Sendable {
    case openFailed(errno: Int32)
    case writeFailed(errno: Int32)
}

/// Append-only JSONL store. See the header comment for why this is a value
/// type with synchronous I/O rather than an actor.
public struct RunHistoryStore: Sendable {
    public let fileURL: URL

    private let logger = Logger(subsystem: "app.ledge", category: "runner")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Appends one record as a single JSON line. Creates the parent
    /// directories on first use. The line is normally one write(2) on an
    /// O_APPEND descriptor, but EINTR/short writes can split a record across
    /// several — the caller-side serialization (see the header) keeps other
    /// records from landing in between, and the torn-tail heal below repairs
    /// the aftermath of a mid-record FAILURE (e.g. ENOSPC after a partial
    /// write): if the file's last byte is not a newline, the new record is
    /// prefixed with one, so the torn fragment becomes its own (skipped)
    /// line instead of silently swallowing this valid record. Calls
    /// `compactIfNeeded()` afterwards so the file can never grow without
    /// bound.
    public func append(_ record: RunRecord) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)

        // O_RDWR (not O_WRONLY) so the heal can pread the current last byte.
        let fd = open(fileURL.path, O_RDWR | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw RunHistoryError.openFailed(errno: errno) }
        defer { close(fd) }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 0 {
            var lastByte: UInt8 = 0
            if pread(fd, &lastByte, 1, info.st_size - 1) == 1, lastByte != 0x0A {
                data.insert(0x0A, at: data.startIndex) // terminate a torn tail
            }
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw RunHistoryError.writeFailed(errno: errno)
                }
                offset += written
            }
        }

        compactIfNeeded()
    }

    /// The newest records for one vault, newest first (file order is append
    /// order, so the last matching lines are the newest — no date sort, no
    /// clock trust). A missing file is an empty history; a corrupt line, a
    /// line of the wrong shape, or a record with an unknown future `outcome`
    /// is skipped silently — the history must never take the picker down.
    /// Unknown future FIELDS on an otherwise valid record are ignored
    /// (JSONDecoder default).
    public func recentRuns(vaultPath: String, limit: Int = 50) -> [RunRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        var matching: [RunRecord] = []
        for line in data.split(separator: 0x0A) {
            guard let record = try? decoder.decode(RunRecord.self, from: Data(line)) else {
                continue // corrupt / foreign / future line: skip, never throw
            }
            if record.vaultPath == vaultPath {
                matching.append(record)
            }
        }
        return Array(matching.suffix(limit).reversed())
    }

    /// When the file exceeds 2× `maxRecords` lines, rewrite it keeping only
    /// the newest `maxRecords` (atomic replace — a crash mid-compaction
    /// leaves the old file intact). The 2× hysteresis keeps compaction rare:
    /// it runs at most once every `maxRecords` appends. Best-effort like the
    /// rest of the history — failures are logged, never thrown.
    ///
    /// Read-then-replace is only safe because writers are serialized (App
    /// layer, see the header): compaction runs inside `append`, on the one
    /// chained history task, so no concurrent append can land between the
    /// read and the rename and be clobbered. Concurrent READS are fine — the
    /// atomic replace hands them either the old or the new file, both
    /// self-consistent.
    public func compactIfNeeded(maxRecords: Int = 500) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > 2 * maxRecords else { return }
        var compacted = Data()
        for line in lines.suffix(maxRecords) {
            compacted.append(line)
            compacted.append(0x0A)
        }
        do {
            try compacted.write(to: fileURL, options: .atomic)
        } catch {
            logger.error(
                "run-history compaction failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
