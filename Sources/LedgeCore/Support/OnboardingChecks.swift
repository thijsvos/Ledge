// §7 onboarding checks. ALL logic lives here — pure and injectable so the
// full matrix (binary missing/present × vault unset/invalid/valid × CLAUDE.md
// absent/present × clause absent/present × git/checkpoints) is unit-testable
// without touching the real filesystem. The App layer only feeds inputs
// (resolver result, defaults) and renders the typed report.
//
// Hard boundaries (§7): Ledge only RECOMMENDS enabling register's checkpoints
// — it never edits the vault's `.register/config.json`. The install-docs link
// is display-only — Ledge never bundles or downloads the CLI (§2.1).

import Foundation

// MARK: - Injectable filesystem seams

/// The filesystem questions the checks ask, as injectable closures. The `live`
/// value hits the real filesystem; tests inject dictionaries.
public struct OnboardingFileChecks: Sendable {
    /// Directory exists at path?
    public var directoryExists: @Sendable (String) -> Bool
    /// Regular file exists at path?
    public var fileExists: @Sendable (String) -> Bool
    /// UTF-8 contents of the file, nil when unreadable/missing.
    public var fileContents: @Sendable (String) -> String?
    /// Vault validity for an expanded path — nil when valid, else the typed
    /// error. The live value delegates to `Vault.init` so the §2.5 rules
    /// (exists, is a directory, never `/`, never `~`) have exactly one home.
    public var validateVault: @Sendable (String) -> VaultError?

    public init(
        directoryExists: @escaping @Sendable (String) -> Bool,
        fileExists: @escaping @Sendable (String) -> Bool,
        fileContents: @escaping @Sendable (String) -> String?,
        validateVault: @escaping @Sendable (String) -> VaultError?
    ) {
        self.directoryExists = directoryExists
        self.fileExists = fileExists
        self.fileContents = fileContents
        self.validateVault = validateVault
    }

    public static let live = OnboardingFileChecks(
        directoryExists: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        },
        fileExists: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        },
        fileContents: { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        },
        validateVault: { path in
            do {
                _ = try Vault(root: URL(fileURLWithPath: path, isDirectory: true))
                return nil
            } catch let error as VaultError {
                return error
            } catch {
                return .rootDoesNotExist(path: path)
            }
        }
    )
}

// MARK: - Typed results

/// Check 1: claude binary found? (§6 resolution result is the input — the
/// checks themselves never spawn anything.)
public enum BinaryCheckResult: Equatable, Sendable {
    /// Found; the UI names the resolved path.
    case found(path: String)
    /// Not found; the UI shows "Claude Code not found" plus the install-docs
    /// link (`OnboardingChecks.installDocsURL`) — display-only, never a
    /// download.
    case notFound
}

/// Check 2: vault path set and Vault-valid?
public enum VaultCheckResult: Equatable, Sendable {
    /// No vault path configured.
    case notConfigured
    /// Configured but invalid — carries Vault's typed error (§2.5 rules).
    case invalid(VaultError)
    /// Valid; `path` is tilde-expanded.
    case valid(path: String)
}

/// Check 3: vault contains a CLAUDE.md?
public enum ClaudeMDCheckResult: Equatable, Sendable {
    /// No valid vault to look inside.
    case skipped
    case missing
    case present
}

/// Check 4: vault has .git → recommend register checkpoints? Text-only:
/// Ledge NEVER edits the vault's config (§7).
public enum CheckpointsCheckResult: Equatable, Sendable {
    /// No valid vault to look inside.
    case skipped
    /// No .git — nothing to recommend.
    case noGit
    /// .git present and `.register/config.json` already has "checkpoints": true.
    case enabled
    /// .git present but checkpoints are not enabled (config missing, invalid,
    /// or lacking `"checkpoints": true`) — recommend enabling, in text only.
    case recommendEnabling
}

/// Check 5: vault CLAUDE.md contains the §7 headless clause?
public enum HeadlessClauseCheckResult: Equatable, Sendable {
    /// No valid vault or no CLAUDE.md to inspect.
    case skipped
    case present
    /// Absent — the UI offers the one-click append
    /// (`OnboardingChecks.appendHeadlessClause(toContentsOf:)`).
    case missing
}

/// The five §7 checks, evaluated together.
public struct OnboardingReport: Equatable, Sendable {
    public let binary: BinaryCheckResult
    public let vault: VaultCheckResult
    public let claudeMD: ClaudeMDCheckResult
    public let checkpoints: CheckpointsCheckResult
    public let headlessClause: HeadlessClauseCheckResult

    public init(
        binary: BinaryCheckResult,
        vault: VaultCheckResult,
        claudeMD: ClaudeMDCheckResult,
        checkpoints: CheckpointsCheckResult,
        headlessClause: HeadlessClauseCheckResult
    ) {
        self.binary = binary
        self.vault = vault
        self.claudeMD = claudeMD
        self.checkpoints = checkpoints
        self.headlessClause = headlessClause
    }
}

// MARK: - The checks

public enum OnboardingChecks {
    /// Shown when the binary is missing. Display-only (§6): Ledge links to the
    /// docs, never downloads or bundles the CLI.
    public static let installDocsURL = "https://docs.anthropic.com/en/docs/claude-code"

    /// The §7 vault-contract addendum, verbatim. `appendHeadlessClause` appends
    /// EXACTLY this block; the containment check is an exact-substring match.
    public static let headlessClause = """
    ## Headless invocations (Ledge)
    When run non-interactively (claude -p): never ask questions. Make the smallest
    conforming edit, record any assumption inline in the affected note as
    "assumption: …", and do not run shell, git, or register commands.
    """

    /// Evaluates all five checks. Pure given the injected `fileChecks`;
    /// `binaryResolution` is the §6 resolver's answer (resolution itself may
    /// spawn a login shell, so it happens outside, off the main actor).
    public static func run(
        binaryResolution: String?,
        vaultPath: String?,
        fileChecks: OnboardingFileChecks = .live
    ) -> OnboardingReport {
        let binary: BinaryCheckResult = binaryResolution.map { .found(path: $0) } ?? .notFound

        let vault: VaultCheckResult
        var vaultRoot: String?
        if let vaultPath, !vaultPath.isEmpty {
            let expanded = (vaultPath as NSString).expandingTildeInPath
            if let error = fileChecks.validateVault(expanded) {
                vault = .invalid(error)
            } else {
                vault = .valid(path: expanded)
                vaultRoot = expanded
            }
        } else {
            vault = .notConfigured
        }

        guard let root = vaultRoot else {
            return OnboardingReport(
                binary: binary,
                vault: vault,
                claudeMD: .skipped,
                checkpoints: .skipped,
                headlessClause: .skipped
            )
        }

        let claudeMDPath = root + "/CLAUDE.md"
        let hasClaudeMD = fileChecks.fileExists(claudeMDPath)

        // ".git" is a DIRECTORY in an ordinary clone but a regular FILE
        // ("gitdir: …") in a linked worktree or submodule — both mean the
        // vault is git-managed, so both trigger the checkpoints check.
        let gitPath = root + "/.git"
        let checkpoints: CheckpointsCheckResult
        if fileChecks.directoryExists(gitPath) || fileChecks.fileExists(gitPath) {
            let config = fileChecks.fileContents(root + "/.register/config.json")
            checkpoints = checkpointsEnabled(configJSON: config) ? .enabled : .recommendEnabling
        } else {
            checkpoints = .noGit
        }

        let headless: HeadlessClauseCheckResult
        if hasClaudeMD {
            let contents = fileChecks.fileContents(claudeMDPath) ?? ""
            headless = containsHeadlessClause(contents) ? .present : .missing
        } else {
            headless = .skipped
        }

        return OnboardingReport(
            binary: binary,
            vault: vault,
            claudeMD: hasClaudeMD ? .present : .missing,
            checkpoints: checkpoints,
            headlessClause: headless
        )
    }

    /// `.register/config.json` has top-level `"checkpoints": true`? Anything
    /// else — missing file, malformed JSON, non-object root, absent key,
    /// false, or a non-boolean value (JSONDecoder is strict: `1` and `"true"`
    /// are NOT booleans) — counts as NOT enabled.
    static func checkpointsEnabled(configJSON: String?) -> Bool {
        struct RegisterConfig: Decodable {
            var checkpoints: Bool?
        }
        guard
            let configJSON,
            let config = try? JSONDecoder().decode(RegisterConfig.self, from: Data(configJSON.utf8))
        else {
            return false
        }
        return config.checkpoints ?? false
    }

    // MARK: - Headless-clause append (§7 one-click)

    public enum HeadlessClauseError: Error, Equatable, Sendable, LocalizedError {
        /// The vault CLAUDE.md does not exist — Ledge never creates it
        /// (`register init` owns that file; §1).
        case fileNotFound(path: String)

        public var errorDescription: String? {
            switch self {
            case let .fileNotFound(path):
                "CLAUDE.md not found: \(path)"
            }
        }
    }

    /// CRLF-tolerant containment. The clause constant uses LF newlines and
    /// Swift treats "\r\n" as ONE grapheme cluster, so an LF pattern can
    /// never match inside CRLF text — a CLAUDE.md saved with Windows-style
    /// endings must still count as "clause present", or the check would
    /// report it missing forever and the one-click append would write a
    /// duplicate copy. Both `run` and `appendingHeadlessClause` go through
    /// this single normalization.
    static func containsHeadlessClause(_ contents: String) -> Bool {
        contents.replacingOccurrences(of: "\r\n", with: "\n").contains(headlessClause)
    }

    /// Pure transform: returns `contents` with the §7 clause appended.
    /// Idempotent — an exact-substring check (CRLF-normalized, see
    /// `containsHeadlessClause`) means the clause is never duplicated. The
    /// block is preceded by a single blank-line separator when `contents`
    /// doesn't already end with one (empty contents get no separator), and
    /// followed by a trailing newline. The suffix inspection also runs on the
    /// normalized form so a CRLF file ending in "\r\n" counts as ending in a
    /// newline; the original contents are returned byte-identical up to the
    /// appended block.
    public static func appendingHeadlessClause(to contents: String) -> String {
        guard !containsHeadlessClause(contents) else { return contents }
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let separator = if normalized.isEmpty || normalized.hasSuffix("\n\n") {
            ""
        } else if normalized.hasSuffix("\n") {
            "\n"
        } else {
            "\n\n"
        }
        return contents + separator + headlessClause + "\n"
    }

    /// File-level one-click append: reads `url`, applies
    /// `appendingHeadlessClause`, writes back atomically. Returns `true` when
    /// the file changed (`false` = clause already present). Throws
    /// `HeadlessClauseError.fileNotFound` when there is no file — the append
    /// never CREATES a CLAUDE.md.
    @discardableResult
    public static func appendHeadlessClause(toContentsOf url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HeadlessClauseError.fileNotFound(path: url.path)
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let updated = appendingHeadlessClause(to: contents)
        guard updated != contents else { return false }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
