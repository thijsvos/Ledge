// Pulling the filing slip out of the agent's reply.
//
// Models wrap JSON in prose and code fences, so this is forgiving in the same
// spirit as StreamParser: try every plausible candidate rather than insisting
// the reply be nothing but JSON. What it will NOT do is guess — if no
// candidate decodes into an EditPlan, that is a typed failure the caller
// reports along with what the agent actually said, so nothing is lost.

import Foundation

public enum EditPlanExtractionError: Error, Equatable, Sendable, LocalizedError {
    /// No brace-balanced JSON object appeared anywhere in the reply.
    case noJSONFound
    /// Objects were found, but none decoded into an EditPlan. Carries the
    /// decoder's reason for the last (most likely) candidate.
    case malformedJSON(String)

    public var errorDescription: String? {
        switch self {
        case .noJSONFound:
            "The agent's reply contained no edit plan"
        case let .malformedJSON(reason):
            "The agent's edit plan could not be read (\(reason))"
        }
    }
}

public enum EditPlanExtractor {
    /// Extracts the plan from an agent's final message.
    ///
    /// Candidates inside ``` fences are preferred (that is what the contract
    /// asks for) and are tried last-first, because the contract asks the agent
    /// to *end* with the plan and any earlier block is more likely an example.
    /// Bare objects in the surrounding prose are the fallback.
    public static func extract(from message: String) throws -> EditPlan {
        let fenced = fencedRegions(in: message).flatMap { balancedObjects(in: $0) }
        let bare = balancedObjects(in: message)
        var lastFailure: String?

        // Spelled with explicit `Array(...)` rather than
        // `fenced.reversed() + bare.reversed()`: `reversed()` has two overloads
        // (Sequence's returning an Array, BidirectionalCollection's returning a
        // ReversedCollection) and concatenating two of them is ambiguous on the
        // Swift 6.0 this package declares. It happened to resolve on a newer
        // toolchain, which is how it reached main — CI on the declared minimum
        // caught it.
        let candidates: [String] = Array(fenced.reversed()) + Array(bare.reversed())

        for candidate in candidates {
            // `Data(_:)` over the UTF-8 view, not `data(using:)`: a String is
            // always representable as UTF-8, so there is no optional to unwrap.
            let data = Data(candidate.utf8)
            do {
                return try JSONDecoder().decode(EditPlan.self, from: data)
            } catch {
                // Not every balanced object is a plan — prose can contain JSON
                // examples. Keep looking; remember why the last one failed.
                lastFailure = Self.reason(for: error)
            }
        }

        if let lastFailure {
            throw EditPlanExtractionError.malformedJSON(lastFailure)
        }
        throw EditPlanExtractionError.noJSONFound
    }

    // MARK: - Scanning

    /// The contents of each ``` fenced region, in order. A language tag such
    /// as `json` needs no special handling — `balancedObjects` steps over any
    /// text that is not part of an object.
    static func fencedRegions(in text: String) -> [String] {
        let parts = text.components(separatedBy: "```")
        guard parts.count > 1 else { return [] }
        // Odd indices are inside fences. A trailing unterminated fence still
        // yields its content, which is the common truncated-output case.
        return stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
    }

    /// Every top-level brace-balanced region in `text`, in order.
    ///
    /// String-aware: a `{` or `}` inside a JSON string literal — entirely
    /// normal in note content — must not open or close a candidate.
    static func balancedObjects(in text: String) -> [String] {
        var found: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 {
                    start = index
                }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let openIndex = start {
                    found.append(String(text[openIndex ... index]))
                    start = nil
                }
            default:
                break
            }
        }
        return found
    }

    /// A short, user-showable reason from a decoding error. `localizedDescription`
    /// on DecodingError is uselessly generic, so the underlying context is used.
    private static func reason(for error: any Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case let .dataCorrupted(context):
            return context.debugDescription
        case let .keyNotFound(key, _):
            return "missing \"\(key.stringValue)\""
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "bad value at \(path)"
        @unknown default:
            return "unrecognized JSON"
        }
    }
}
