// The filing slip (§2.3). Instead of writing the vault itself, the agent ends
// its reply with an edit plan and Ledge does the writing. Three operations,
// deliberately — and no delete, so the worst a malformed or hostile plan can
// do is add markdown Ledge can undo.
//
// `replace` mirrors the old/new-string contract of Claude's own Edit tool: it
// is a shape the model already knows, and it means a one-line change does not
// cost the output tokens of retyping the whole file.

import Foundation

/// A set of edits an agent proposes. An empty plan is valid and means
/// "nothing needed changing" — a real answer, not a failure.
public struct EditPlan: Equatable, Sendable, Codable {
    public var edits: [Edit]

    public init(edits: [Edit]) {
        self.edits = edits
    }

    public var isEmpty: Bool {
        edits.isEmpty
    }

    public enum Edit: Equatable, Sendable {
        /// A file that must not already exist. Intermediate folders are
        /// created by the applier.
        case create(path: String, content: String)
        /// Text added to the end of a file that must already exist.
        case append(path: String, text: String)
        /// `find` must appear exactly once in the file, so a replacement can
        /// never land on the wrong occurrence.
        case replace(path: String, find: String, with: String)

        /// The vault-relative path this edit names, before fencing.
        public var path: String {
            switch self {
            case let .create(path, _): path
            case let .append(path, _): path
            case let .replace(path, _, _): path
            }
        }

        /// The wire name of the operation, for logs and refusal messages.
        public var operationName: String {
            switch self {
            case .create: "create"
            case .append: "append"
            case .replace: "replace"
            }
        }
    }
}

// MARK: - Wire format

extension EditPlan.Edit: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, path, content, text, find, with
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        // Case-folded: a model that emits "Append" is being unhelpful, not
        // wrong, and the refusal would cost the user a whole run.
        let op = try container.decode(String.self, forKey: .op).lowercased()
        switch op {
        case "create":
            self = try .create(path: path, content: container.decode(String.self, forKey: .content))
        case "append":
            self = try .append(path: path, text: container.decode(String.self, forKey: .text))
        case "replace":
            self = try .replace(
                path: path,
                find: container.decode(String.self, forKey: .find),
                with: container.decode(String.self, forKey: .with)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: container,
                debugDescription: "unknown edit operation \"\(op)\""
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationName, forKey: .op)
        try container.encode(path, forKey: .path)
        switch self {
        case let .create(_, content):
            try container.encode(content, forKey: .content)
        case let .append(_, text):
            try container.encode(text, forKey: .text)
        case let .replace(_, find, with):
            try container.encode(find, forKey: .find)
            try container.encode(with, forKey: .with)
        }
    }
}
