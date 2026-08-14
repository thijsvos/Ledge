// Vault path fencing (§2.3, §2.5). `Vault.init` proves the ROOT is sane; this
// proves every CHILD path is. Until edit plans existed, no untrusted input ever
// named a file — the agent held the pen and its allowlist was the fence. Now
// Ledge holds the pen, so the fence is code here, with tests against it.
//
// The rules are deliberately strict rather than clever: a filing slip has no
// legitimate use for `..`, for a dotfile, or for a non-markdown path, so all
// three are refused outright instead of being normalized into something safe.

import Foundation
import os

public extension Vault {
    /// Typed refusals for an agent-supplied path. Every case is a path Ledge
    /// will not write to under any circumstances.
    enum PathRejection: Error, Equatable, Sendable, LocalizedError {
        case empty
        /// `/etc/passwd.md` — absolute paths never name a vault file.
        case absolutePath(String)
        /// `~/notes.md` — Ledge does not expand tildes for the agent.
        case tildePath(String)
        /// Contains a `..` component. Refused outright (see file header).
        case parentTraversal(String)
        /// A path component begins with `.`. This is what stops an agent
        /// writing into the vault's own `.claude/commands`, which
        /// SlashCommandCatalog reads — a slash command Ledge would later
        /// offer the user is not something an unattended run may author.
        case hiddenComponent(String)
        /// A symlink inside the vault resolves to somewhere outside it.
        case escapesVault(String)
        /// Not a `.md` file. Case-sensitive, matching `inboxURL()`'s glob.
        case notMarkdown(String)
        /// The path names an existing directory.
        case isADirectory(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                "Refused: empty path"
            case let .absolutePath(path):
                "Refused: absolute path (\(path))"
            case let .tildePath(path):
                "Refused: home-relative path (\(path))"
            case let .parentTraversal(path):
                "Refused: path climbs out of the vault (\(path))"
            case let .hiddenComponent(path):
                "Refused: hidden path (\(path))"
            case let .escapesVault(path):
                "Refused: path escapes the vault (\(path))"
            case let .notMarkdown(path):
                "Refused: not a markdown file (\(path))"
            case let .isADirectory(path):
                "Refused: path is a folder (\(path))"
            }
        }
    }

    /// Resolves an agent-supplied relative path to a URL provably inside this
    /// vault, or throws the reason it was refused.
    ///
    /// The leaf need not exist — `create` names a file that does not yet. That
    /// is why symlinks cannot simply be resolved on the whole path: instead the
    /// walk below resolves each component that *does* exist and re-checks
    /// containment, then appends the rest verbatim. A component that does not
    /// exist cannot be a symlink, and nothing can exist beneath it, so the
    /// containment proof holds for the whole path.
    func resolve(relativePath raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PathRejection.empty }
        guard !trimmed.hasPrefix("/") else { throw PathRejection.absolutePath(trimmed) }
        guard !trimmed.hasPrefix("~") else { throw PathRejection.tildePath(trimmed) }
        guard trimmed.hasSuffix(".md") else { throw PathRejection.notMarkdown(trimmed) }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !components.isEmpty else { throw PathRejection.empty }
        guard !components.contains("..") else { throw PathRejection.parentTraversal(trimmed) }
        guard !components.contains(where: { $0.hasPrefix(".") }) else {
            throw PathRejection.hiddenComponent(trimmed)
        }

        // The root is resolved once so that /tmp → /private/tmp (and any other
        // symlinked ancestor) is compared like with like.
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var current = resolvedRoot
        var reachedMissingComponent = false

        for component in components {
            current.appendPathComponent(component)
            guard !reachedMissingComponent else { continue }
            if FileManager.default.fileExists(atPath: current.path) {
                current = current.resolvingSymlinksInPath()
                guard Self.isDescendant(current, of: resolvedRoot) else {
                    Logger(subsystem: "app.ledge", category: "vault").error(
                        "refused agent path escaping the vault: \(trimmed, privacy: .public)"
                    )
                    throw PathRejection.escapesVault(trimmed)
                }
            } else {
                reachedMissingComponent = true
            }
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
           isDirectory.boolValue
        {
            throw PathRejection.isADirectory(trimmed)
        }
        return current
    }

    /// True when `url` sits strictly beneath `root`. The trailing separator
    /// matters: `/vault-backup` must not read as a child of `/vault`.
    internal static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return url.path.hasPrefix(prefix)
    }
}
