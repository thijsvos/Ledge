// Incremental NDJSON parser for `claude -p … --output-format stream-json`
// (§6). Coded against the OBSERVED stream (Tests/fixtures/live-probe.ndjson,
// claude 2.1.226), not just the spec's three representative shapes: the real
// stream also carries hook_started/hook_response system subtypes,
// rate_limit_event, thinking content blocks, stop_reason fields, … — every
// unknown type/subtype/field is silently skipped. Plain struct, no I/O.

import Foundation

/// The extracted `type:"result"` event (observed reality: `subtype:"success"`,
/// `is_error:false`, `session_id`, `duration_ms`, `num_turns`,
/// `total_cost_usd`, `result:"<text>"`).
public struct RunResultEvent: Sendable, Equatable {
    public let sessionID: String?
    /// True when `is_error` is true OR `subtype` is present and ≠ "success".
    public let isError: Bool
    /// The raw `subtype` (e.g. "success", "error_max_turns") — kept so an
    /// error result on a zero exit can be surfaced as the CLI-reported cause.
    public let subtype: String?
    public let durationMS: Int?
    public let numTurns: Int?
    public let totalCostUSD: Double?
    public let resultText: String?

    public init(
        sessionID: String?,
        isError: Bool,
        subtype: String?,
        durationMS: Int?,
        numTurns: Int?,
        totalCostUSD: Double?,
        resultText: String?
    ) {
        self.sessionID = sessionID
        self.isError = isError
        self.subtype = subtype
        self.durationMS = durationMS
        self.numTurns = numTurns
        self.totalCostUSD = totalCostUSD
        self.resultText = resultText
    }
}

/// Feed raw stdout chunks with `feed(_:)` (any chunking, down to single
/// bytes — a partial trailing line is buffered), then `finish()` to flush a
/// final unterminated line. Malformed lines are counted, never fatal.
public struct StreamParser: Sendable {
    /// From the `system`/`init` event (persisted for `--resume`).
    public private(set) var sessionID: String?
    /// Assistant `text` content blocks, in order (kept for a detail view).
    public private(set) var transcript: [String] = []
    /// `input.file_path` of Write/Edit tool_use blocks — ordered, de-duplicated.
    public private(set) var editedFiles: [String] = []
    /// The final `result` event, if one arrived.
    public private(set) var result: RunResultEvent?
    /// Lines that were not a JSON object. Empty/whitespace-only lines (the
    /// stream ends with a newline) are skipped without counting.
    public private(set) var malformedLineCount = 0

    private var buffer = Data()
    private var editedFileSet = Set<String>()

    public init() {}

    /// Appends a chunk and processes every complete (newline-terminated) line.
    public mutating func feed(_ data: Data) {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex ..< newlineIndex)
            buffer = buffer.subdata(in: buffer.index(after: newlineIndex) ..< buffer.endIndex)
            process(line: line)
        }
    }

    /// Flushes a trailing line that never got its newline (stream ended).
    public mutating func finish() {
        if !buffer.isEmpty {
            process(line: buffer)
            buffer.removeAll()
        }
    }

    // MARK: - Per-line processing

    private mutating func process(line: Data) {
        var line = line
        if line.last == 0x0D {
            line = line.dropLast()
        } // tolerate \r\n
        // Skip blank lines silently (space, tab, \r).
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return }

        guard
            let parsed = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]),
            let object = parsed as? [String: Any]
        else {
            malformedLineCount += 1
            return
        }
        extract(from: object)
    }

    private mutating func extract(from object: [String: Any]) {
        switch object["type"] as? String {
        case "system":
            if object["subtype"] as? String == "init",
               let id = object["session_id"] as? String
            {
                sessionID = id
            }
        case "assistant":
            guard
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? [Any]
            else { return }
            for case let block as [String: Any] in content {
                extract(fromContentBlock: block)
            }
        case "result":
            result = RunResultEvent(
                sessionID: object["session_id"] as? String,
                isError: (object["is_error"] as? Bool ?? false)
                    || ((object["subtype"] as? String) ?? "success") != "success",
                subtype: object["subtype"] as? String,
                durationMS: object["duration_ms"] as? Int,
                numTurns: object["num_turns"] as? Int,
                totalCostUSD: object["total_cost_usd"] as? Double,
                resultText: object["result"] as? String
            )
        default:
            break // unknown event type (rate_limit_event, …): skip silently
        }
    }

    private mutating func extract(fromContentBlock block: [String: Any]) {
        switch block["type"] as? String {
        case "text":
            if let text = block["text"] as? String {
                transcript.append(text)
            }
        case "tool_use":
            guard
                let name = block["name"] as? String,
                name == "Write" || name == "Edit",
                let input = block["input"] as? [String: Any],
                let filePath = input["file_path"] as? String,
                editedFileSet.insert(filePath).inserted
            else { return }
            editedFiles.append(filePath)
        default:
            break // thinking blocks, tool_result, …: skip silently
        }
    }
}
