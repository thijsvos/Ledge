// Checking a filing slip before any of it is applied (§2.3).
//
// Nothing is written until every edit has passed. That matters because a plan
// is a batch: applying the first three edits and then discovering the fourth
// names /etc/passwd would leave the vault half-changed for no good reason.
//
// Validation walks the edits in order against a *projected* view of the vault,
// not the on-disk one, so a plan that creates a file and then appends to it is
// checked the way it will actually run.

import Foundation

public enum EditPlanRejection: Error, Equatable, Sendable, LocalizedError {
    case tooManyEdits(count: Int, limit: Int)
    case tooLarge(bytes: Int, limit: Int)
    case path(index: Int, path: String, reason: Vault.PathRejection)
    case fileExists(index: Int, path: String)
    case fileMissing(index: Int, path: String)
    case emptyFind(index: Int, path: String)
    case findNotFound(index: Int, path: String)
    case findNotUnique(index: Int, path: String, count: Int)
    case unreadable(index: Int, path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .tooManyEdits(count, limit):
            "Refused: plan has \(count) edits (limit \(limit))"
        case let .tooLarge(bytes, limit):
            "Refused: plan writes \(bytes) bytes (limit \(limit))"
        case let .path(_, _, reason):
            reason.errorDescription
        case let .fileExists(_, path):
            "Refused: \(path) already exists"
        case let .fileMissing(_, path):
            "Refused: \(path) does not exist"
        case let .emptyFind(_, path):
            "Refused: empty find text for \(path)"
        case let .findNotFound(_, path):
            "Refused: find text not present in \(path)"
        case let .findNotUnique(_, path, count):
            "Refused: find text appears \(count) times in \(path)"
        case let .unreadable(_, path, reason):
            "Refused: could not read \(path) (\(reason))"
        }
    }
}

/// A plan that has passed every check, paired with the exact bytes to write.
public struct ValidatedPlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let edit: EditPlan.Edit
        public let url: URL
        /// Contents when the plan was checked; nil means "did not exist".
        /// Re-checked at apply time so a concurrent external write is refused
        /// rather than clobbered, and reused as the undo pre-image.
        public let before: String?
        /// The exact contents this step writes.
        public let after: String
    }

    public let steps: [Step]
    /// New material this plan contributes, in bytes.
    public let bytesWritten: Int

    public var isEmpty: Bool {
        steps.isEmpty
    }
}

public enum EditPlanValidator {
    /// Blast-radius caps. Note what bounds *deletion*: `replace` is the only
    /// operation that can remove text, and it requires the agent to reproduce
    /// the exact text it removes — which undo then restores.
    public static let maxEdits = 20
    public static let maxBytesWritten = 1_000_000

    /// Checks every edit against the vault fence and returns the exact bytes
    /// each one will write, or throws the first refusal. Nothing touches disk.
    ///
    /// The walk is ordered and stateful: later edits see the projected result
    /// of earlier ones, so create-then-append to the same path is legal and is
    /// checked the way it will actually run. `maxBytesWritten` sums only the
    /// NEW material each edit contributes — an append's text, not the file it
    /// lands in — so a plan is measured by what it adds rather than by what it
    /// re-states.
    ///
    /// The result is a SNAPSHOT: each step carries the file contents as they
    /// were during this call, and the applier refuses any file whose contents
    /// moved since. Holding a `ValidatedPlan` and applying it much later is
    /// therefore not cheaper, it is a `changedUnderfoot` waiting to happen —
    /// validate and apply back to back.
    public static func validate(_ plan: EditPlan, in vault: Vault) throws -> ValidatedPlan {
        guard plan.edits.count <= maxEdits else {
            throw EditPlanRejection.tooManyEdits(count: plan.edits.count, limit: maxEdits)
        }

        // Projected vault state: URL → contents, where a present-but-nil value
        // means "an earlier step in this same plan established it is absent".
        var projected: [URL: String?] = [:]
        var steps: [ValidatedPlan.Step] = []
        var bytesWritten = 0

        for (index, edit) in plan.edits.enumerated() {
            let url: URL
            do {
                url = try vault.resolve(relativePath: edit.path)
            } catch let rejection as Vault.PathRejection {
                throw EditPlanRejection.path(index: index, path: edit.path, reason: rejection)
            }

            let current: String? = if let known = projected[url] {
                known
            } else {
                try readIfPresent(url, index: index, path: edit.path)
            }

            let after: String
            switch edit {
            case let .create(_, content):
                guard current == nil else {
                    throw EditPlanRejection.fileExists(index: index, path: edit.path)
                }
                after = content
                bytesWritten += content.utf8.count

            case let .append(_, text):
                guard let existing = current else {
                    throw EditPlanRejection.fileMissing(index: index, path: edit.path)
                }
                // Same newline repair InstantCapture applies, so an appended
                // entry always starts on its own line.
                let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                after = existing + separator + text
                bytesWritten += text.utf8.count

            case let .replace(_, find, with):
                guard let existing = current else {
                    throw EditPlanRejection.fileMissing(index: index, path: edit.path)
                }
                guard !find.isEmpty else {
                    throw EditPlanRejection.emptyFind(index: index, path: edit.path)
                }
                let matches = occurrenceCount(of: find, in: existing)
                guard matches > 0 else {
                    throw EditPlanRejection.findNotFound(index: index, path: edit.path)
                }
                guard matches == 1 else {
                    throw EditPlanRejection.findNotUnique(
                        index: index, path: edit.path, count: matches
                    )
                }
                after = existing.replacingOccurrences(of: find, with: with, options: .literal)
                bytesWritten += with.utf8.count
            }

            guard bytesWritten <= maxBytesWritten else {
                throw EditPlanRejection.tooLarge(bytes: bytesWritten, limit: maxBytesWritten)
            }

            steps.append(ValidatedPlan.Step(edit: edit, url: url, before: current, after: after))
            projected[url] = after
        }

        return ValidatedPlan(steps: steps, bytesWritten: bytesWritten)
    }

    // MARK: - Helpers

    private static func readIfPresent(_ url: URL, index: Int, path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // A vault file that is not valid UTF-8 is not something an
            // unattended run gets to rewrite.
            throw EditPlanRejection.unreadable(
                index: index, path: path, reason: error.localizedDescription
            )
        }
    }

    /// Non-overlapping literal occurrences. Literal, not standard comparison:
    /// find/replace is a byte contract, and two strings that compare equal
    /// under canonical equivalence are not the same bytes.
    static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let found = haystack.range(
                  of: needle, options: .literal, range: searchStart ..< haystack.endIndex
              )
        {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}
