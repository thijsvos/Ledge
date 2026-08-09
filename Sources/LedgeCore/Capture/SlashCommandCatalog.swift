// Slash-command typeahead catalog: a pure filesystem scan of the user's
// Claude Code custom commands and skills, so the capture field can suggest
// them while the user types "/…". Never spawns `claude`.
//
// §2 discipline: the scan reads ONLY `<base>/.claude/commands` and
// `<base>/.claude/skills` (base = user home and the vault root). `~/.claude`
// itself is never enumerated, so credentials, settings, and any other
// auth-related material are never touched.

import Foundation
import os

/// One suggestible slash command.
public struct SlashCommand: Equatable, Sendable {
    /// Where the command was discovered; also its dedupe priority (project
    /// beats user, command beats skill) and its group in catalog ordering.
    public enum Source: Equatable, Sendable {
        case projectCommand
        case projectSkill
        case userCommand
        case userSkill
    }

    /// The command name WITHOUT the leading slash. For commands this is the
    /// file's path relative to `commands/` minus the `.md` extension, with
    /// path separators replaced by ":" (Claude Code namespacing, e.g.
    /// `foo/bar.md` → "foo:bar"). For skills it is the frontmatter `name:`
    /// value, else the skill directory's name.
    public let name: String
    /// Frontmatter `description:`, if present and non-empty.
    public let description: String?
    /// Frontmatter `argument-hint:`, if present and non-empty.
    public let argumentHint: String?
    public let source: Source

    public init(
        name: String,
        description: String? = nil,
        argumentHint: String? = nil,
        source: Source
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
    }
}

/// The scanned command list plus prefix filtering. `scan` does the I/O once
/// (per island open, driven by the App layer); `matching` is pure and cheap
/// enough to run per keystroke.
public struct SlashCommandCatalog: Equatable, Sendable {
    /// Deduped and ordered: projectCommand, projectSkill, userCommand,
    /// userSkill; alphabetical within each group.
    public let commands: [SlashCommand]

    public init(commands: [SlashCommand] = []) {
        self.commands = commands
    }

    /// Case-insensitive name-prefix filter preserving catalog order. The
    /// empty prefix matches everything.
    public func matching(prefix: String) -> [SlashCommand] {
        guard !prefix.isEmpty else { return commands }
        let needle = prefix.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(needle) }
    }

    /// Submit-time slash restoration. The §5 router hands the runner
    /// everything AFTER the leading "/", but headless claude dispatches a
    /// custom command or skill only when the prompt string itself starts
    /// with "/" — a slash-less command name arrives as ordinary prose. If
    /// `prompt`'s first whitespace-delimited token exactly names a catalog
    /// command, this restores the slash; any other prompt (freeform agent
    /// text) is returned unchanged, preserving the §5 contract.
    ///
    /// The match is exact (case-sensitive): typeahead completion inserts the
    /// exact catalog name, and a wrong-cased hand-typed name flows through
    /// unchanged — the same prose behavior it had before this feature.
    /// Prompt content is not part of the pinned §2.3 argv shape, so this
    /// never touches the sandbox flags.
    public func restoringCommandSlash(_ prompt: String) -> String {
        let token = prompt.prefix(while: { !$0.isWhitespace })
        guard !token.isEmpty, commands.contains(where: { $0.name == token }) else {
            return prompt
        }
        return "/" + prompt
    }

    // MARK: - Scan

    /// Directories deeper than this below `commands/` are not entered, so a
    /// command name has at most 3 colon-separated components (`a:b:c`).
    static let maxCommandDepth = 3

    /// Scans both bases and returns the deduped, ordered command list.
    /// Missing or unreadable directories contribute nothing; the scan never
    /// throws. Symbolic links are never followed (no cycles); hidden files
    /// and directories are skipped.
    public static func scan(vaultRoot: URL?, userHome: URL) -> [SlashCommand] {
        let start = ContinuousClock.now
        var found: [SlashCommand] = []
        if let vaultRoot {
            found += scanBase(vaultRoot, commandSource: .projectCommand, skillSource: .projectSkill)
        }
        found += scanBase(userHome, commandSource: .userCommand, skillSource: .userSkill)
        let result = orderedAndDeduped(found)
        Logger(subsystem: "app.ledge", category: "capture").info(
            "slash-command scan: \(result.count) commands (\(found.count) before dedupe) in \(ContinuousClock.now - start)"
        )
        return result
    }

    private static func scanBase(
        _ base: URL, commandSource: SlashCommand.Source, skillSource: SlashCommand.Source
    ) -> [SlashCommand] {
        // Only these two subtrees are ever read — never `.claude` itself (§2).
        // The enumeration ROOTS get the same symlink discipline as their
        // entries: a vault is cloned/synced content, so a crafted
        // `<vault>/.claude/commands → ~/.claude` symlink must not redirect
        // the scan outside the sanctioned subtrees. A symlinked root simply
        // contributes nothing.
        let claudeDir = base.appendingPathComponent(".claude", isDirectory: true)
        guard !isSymbolicLink(claudeDir) else { return [] }
        var commands: [SlashCommand] = []
        let commandsDir = claudeDir.appendingPathComponent("commands", isDirectory: true)
        if !isSymbolicLink(commandsDir) {
            commands += collectCommands(
                in: commandsDir, namePrefix: "", depth: 1, source: commandSource
            )
        }
        let skillsDir = claudeDir.appendingPathComponent("skills", isDirectory: true)
        if !isSymbolicLink(skillsDir) {
            commands += collectSkills(in: skillsDir, source: skillSource)
        }
        return commands
    }

    /// `<commands>/**/*.md`, recursion capped at `maxCommandDepth` levels.
    private static func collectCommands(
        in directory: URL, namePrefix: String, depth: Int, source: SlashCommand.Source
    ) -> [SlashCommand] {
        guard depth <= maxCommandDepth, let entries = children(of: directory) else { return [] }
        var commands: [SlashCommand] = []
        for entry in entries {
            let filename = entry.lastPathComponent
            if filename.hasPrefix(".") || isSymbolicLink(entry) {
                continue
            }
            if isDirectory(entry) {
                commands += collectCommands(
                    in: entry,
                    namePrefix: namePrefix + filename + ":",
                    depth: depth + 1,
                    source: source
                )
            } else if filename.hasSuffix(".md") {
                let frontmatter = Frontmatter.parse(fileAt: entry)
                commands.append(SlashCommand(
                    name: namePrefix + entry.deletingPathExtension().lastPathComponent,
                    description: frontmatter.description,
                    argumentHint: frontmatter.argumentHint,
                    source: source
                ))
            }
        }
        return commands
    }

    /// `<skills>/<dir>/SKILL.md`, one level only. Name = frontmatter `name:`
    /// if present, else the directory name.
    private static func collectSkills(
        in directory: URL, source: SlashCommand.Source
    ) -> [SlashCommand] {
        guard let entries = children(of: directory) else { return [] }
        var commands: [SlashCommand] = []
        for entry in entries {
            let dirName = entry.lastPathComponent
            if dirName.hasPrefix(".") || isSymbolicLink(entry) || !isDirectory(entry) {
                continue
            }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard !isSymbolicLink(skillFile),
                  FileManager.default.fileExists(atPath: skillFile.path)
            else { continue }
            let frontmatter = Frontmatter.parse(fileAt: skillFile)
            commands.append(SlashCommand(
                name: frontmatter.name ?? dirName,
                description: frontmatter.description,
                argumentHint: frontmatter.argumentHint,
                source: source
            ))
        }
        return commands
    }

    // MARK: - Ordering & dedupe

    /// Sort by (group priority, case-insensitively alphabetical name), then
    /// keep the FIRST occurrence of each exact name — which is the
    /// highest-priority one: projectCommand > projectSkill > userCommand >
    /// userSkill, i.e. project beats user and command beats skill.
    private static func orderedAndDeduped(_ commands: [SlashCommand]) -> [SlashCommand] {
        let sorted = commands.sorted { a, b in
            if a.source.priority != b.source.priority {
                return a.source.priority < b.source.priority
            }
            let aName = a.name.lowercased()
            let bName = b.name.lowercased()
            if aName != bName {
                return aName < bName
            }
            return a.name < b.name
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.name).inserted }
    }

    // MARK: - Filesystem helpers (never throw, never follow symlinks)

    private static func children(of directory: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

private extension SlashCommand.Source {
    /// Dedupe/ordering priority; lower wins.
    var priority: Int {
        switch self {
        case .projectCommand: 0
        case .projectSkill: 1
        case .userCommand: 2
        case .userSkill: 3
        }
    }
}

/// Minimal YAML-frontmatter reader (no YAML dependency): if the file starts
/// with `---`, simple one-line `key: value` pairs are read until the closing
/// `---`. Tolerates CRLF and a UTF-8 BOM; strips one pair of surrounding
/// quotes from values; empty values count as absent. A file with no
/// frontmatter, an unclosed block, or a block whose closing `---` lies beyond
/// the first 4 KB yields all-nil fields. Never throws, never reads more than
/// the first 4 KB. Internal (not private) so the parser is directly testable.
struct Frontmatter {
    var name: String?
    var description: String?
    var argumentHint: String?

    /// Only this many leading bytes are ever read.
    static let maxBytes = 4096

    static func parse(fileAt url: URL) -> Frontmatter {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Frontmatter() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else {
            return Frontmatter()
        }
        // A 4 KB cut can split a UTF-8 sequence; String(decoding:) replaces
        // the fragment instead of failing.
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> Frontmatter {
        // Split on any Unicode line break. CRLF is ONE `Character` in Swift,
        // so this — unlike splitting on "\n" — handles CRLF files, and the
        // separator swallows the \r with it.
        var lines = text
            .dropFirst(text.hasPrefix("\u{FEFF}") ? 1 : 0)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        guard let first = lines.first, isDelimiter(first) else { return Frontmatter() }
        lines = lines.dropFirst()

        var frontmatter = Frontmatter()
        for line in lines {
            if isDelimiter(line) {
                return frontmatter // closed block: whatever was found stands
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = trimmed(line[..<colon]).lowercased()
            let value = stripQuotes(trimmed(line[line.index(after: colon)...]))
            guard !value.isEmpty else { continue }
            switch key {
            case "name": frontmatter.name = value
            case "description": frontmatter.description = value
            case "argument-hint": frontmatter.argumentHint = value
            default: break
            }
        }
        return Frontmatter() // never closed (or closing --- beyond 4 KB): broken → all nil
    }

    /// True for a `---` line; tolerates surrounding whitespace and a
    /// trailing CR (CRLF files).
    private static func isDelimiter(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }

    private static func trimmed(_ substring: Substring) -> String {
        substring.trimmingCharacters(in: .whitespaces)
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
    }
}
