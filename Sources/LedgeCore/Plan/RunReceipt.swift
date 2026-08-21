// What a run actually did, in a form the notch can show (§2.3).
//
// Ledge's safety story is thorough on what the agent CANNOT do — read-only,
// path-fenced, capped, no delete — and thin on what it DID do. A finished run
// reports "✓ 2 files" and drops the paths, so the only way to see the change
// has been to open a terminal and run `git diff`, which the vault may not even
// support.
//
// No diff algorithm is needed for this, and no file content has to be kept.
// An `EditPlan.Edit` already describes its own change completely: `create`
// carries the new file, `append` the appended text, `replace` both the removed
// and the added text. The applier holds those strings and used to drop them;
// `AppliedPlan.changes` now carries them here.

import Foundation

/// One run's changes, ready to render. Plain data with no tie to the vault or
/// the run, matching `RunUndoRecord` — the App layer holds one, in memory, for
/// the last applied run, and drops it when `/undo` reverses that run.
public struct RunReceipt: Equatable, Sendable {
    /// What the agent said it did. Its own words, shown above its edits so the
    /// claim and the evidence sit together.
    public let explanation: String?
    public let files: [FileChange]

    public struct FileChange: Equatable, Sendable {
        /// Vault-relative, as the agent named it — never an absolute path.
        public let path: String
        /// The run created this file rather than editing one that existed.
        public let isNew: Bool
        public let edits: [EditPlan.Edit]
    }

    public var isEmpty: Bool {
        files.isEmpty
    }

    /// Builds a receipt from what the applier retained.
    ///
    /// Grouped by file in first-touched order, so several edits to one note
    /// read as one entry. `isNew` comes from the undo record: a nil pre-image
    /// is precisely "this file did not exist", which is the same fact `/undo`
    /// uses to decide between restoring and deleting.
    public init(applied: AppliedPlan, explanation: String? = nil) {
        let trimmed = explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.explanation = (trimmed?.isEmpty ?? true) ? nil : trimmed

        let createdURLs = Set(
            applied.undo.entries.filter { $0.before == nil }.map(\.url)
        )
        var order: [URL] = []
        var grouped: [URL: [EditPlan.Edit]] = [:]
        for change in applied.changes {
            if grouped[change.url] == nil {
                order.append(change.url)
            }
            grouped[change.url, default: []].append(change.edit)
        }
        files = order.map { url in
            let edits = grouped[url] ?? []
            return FileChange(
                // The edit's own path is vault-relative and is what the user
                // typed about; `url` is absolute and would leak a home folder.
                path: edits.first?.path ?? url.lastPathComponent,
                isNew: createdURLs.contains(url),
                edits: edits
            )
        }
    }
}

public extension RunReceipt {
    /// One line of the rendered receipt.
    struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// The agent's own words.
            case explanation
            /// A file heading. `isNew` marks a file the run created.
            case file(isNew: Bool)
            case added
            case removed
            /// "+3 more" — a file's changes were longer than the pane allows.
            case elision
        }

        public let kind: Kind
        public let text: String
    }

    /// Renders the receipt as display rows.
    ///
    /// `maxLinesPerFile` bounds each file's contribution, because the notch
    /// window is a hard 200 pt (§4) and gives roughly seven rows: one runaway
    /// `create` would otherwise push every other file out of sight. Blank lines
    /// are dropped — they carry nothing at this size and cost a whole row.
    func rows(maxLinesPerFile: Int = 6) -> [Row] {
        var rows: [Row] = []
        if let explanation {
            rows.append(Row(kind: .explanation, text: explanation))
        }
        for file in files {
            rows.append(Row(kind: .file(isNew: file.isNew), text: file.path))

            var lines: [Row] = []
            for edit in file.edits {
                switch edit {
                case let .create(_, content):
                    lines += Self.lineRows(content, kind: .added)
                case let .append(_, text):
                    lines += Self.lineRows(text, kind: .added)
                case let .replace(_, find, with):
                    lines += Self.lineRows(find, kind: .removed)
                    lines += Self.lineRows(with, kind: .added)
                }
            }
            if lines.count > maxLinesPerFile {
                let shown = max(0, maxLinesPerFile - 1)
                rows += lines.prefix(shown)
                rows.append(Row(kind: .elision, text: "+\(lines.count - shown) more"))
            } else {
                rows += lines
            }
        }
        return rows
    }

    private static func lineRows(_ text: String, kind: Row.Kind) -> [Row] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Row(kind: kind, text: $0) }
    }
}
