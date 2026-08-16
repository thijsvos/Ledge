// What Ledge asks the agent for (§2.3).
//
// The contract travels in the prompt rather than in the vault's CLAUDE.md for
// two reasons: Ledge then works against a vault with no agent config in it at
// all, and the same wording will carry to other CLIs unchanged.
//
// The UTC date AND time are injected deliberately. register's convention is
// that everything is UTC (see Vault.dayStamp / Vault.timeStamp), but a CLI
// injects its own *local* date into context and no clock at all — so an agent
// left to work it out names the wrong daily note for anyone west of UTC after
// 00:00Z, and stamps log entries with whatever the worked example showed.
// Human QA caught the second one: every filed entry came back "00:00Z".
//
// The example below therefore carries the real current time, so the shape the
// agent copies and the value it copies are both right, and both match what
// InstantCapture writes for a plain capture.
//
// The example leads with `replace`, not `append`, for the same reason. Human QA
// caught that too: a log line filed into a daily note with `## Log` above
// `## Tasks` landed under Tasks, because append goes to the END of the file and
// the old example demonstrated appending to exactly that note. The example is
// the strongest instruction in this contract — it has to model the right move.

import Foundation

public enum PlanContract {
    /// What the agent writes where a note's ULID belongs. A placeholder rather
    /// than a real ID because the agent cannot mint one (see `ULID`) — and a
    /// placeholder rather than a supplied list because a plan may create any
    /// number of notes, and running out silently would put us back to invented
    /// IDs.
    public static let idPlaceholder = "{{ulid}}"

    /// Replaces every `idPlaceholder` in a plan with a freshly minted ULID —
    /// one per occurrence, so two notes in the same plan never collide.
    ///
    /// Runs BEFORE validation, so the byte caps count what will actually be
    /// written and the applier's pre-images match the bytes on disk. `find` is
    /// deliberately untouched: it must match the file byte for byte, so a
    /// placeholder there is a mistake that should fail loudly rather than be
    /// rewritten into something that cannot match either.
    public static func fillingIdentifiers(in plan: EditPlan, now: Date = Date()) -> EditPlan {
        EditPlan(edits: plan.edits.map { edit in
            switch edit {
            case let .create(path, content):
                .create(path: path, content: filling(content, now: now))
            case let .append(path, text):
                .append(path: path, text: filling(text, now: now))
            case let .replace(path, find, with):
                .replace(path: path, find: find, with: filling(with, now: now))
            }
        })
    }

    private static func filling(_ text: String, now: Date) -> String {
        guard text.contains(idPlaceholder) else { return text }
        var result = ""
        var rest = Substring(text)
        while let found = rest.range(of: idPlaceholder) {
            result += rest[rest.startIndex ..< found.lowerBound]
            result += ULID.make(at: now)
            rest = rest[found.upperBound...]
        }
        return result + rest
    }

    /// Wraps the user's prompt in the edit-plan contract. The user's own words
    /// come last: they are what the agent should act on, and recency helps.
    public static func wrap(prompt: String, now: Date = Date()) -> String {
        """
        You are filing a note into a markdown vault. It is now \
        \(Vault.dayStamp(on: now)) \(Vault.timeStamp(on: now))Z (UTC — this vault dates \
        and times everything in UTC).

        You have read-only access. Explore with Read, Glob and Grep, then report what \
        should change. Do NOT try to write, edit or create files: you have no tools for \
        it and Ledge performs every write itself.

        End your reply with exactly one fenced json block holding an edit plan:

        ```json
        {"edits": [
          {"op": "replace", "path": "daily/\(Vault.dayStamp(on: now)).md", "find": "## Log\\n- 09:00Z An earlier entry", "with": "## Log\\n- 09:00Z An earlier entry\\n- \(Vault.timeStamp(on: now))Z Something"},
          {"op": "create", "path": "notes/new-thing.md", "content": "# New thing\\n"},
          {"op": "append", "path": "notes/a-flat-note.md", "text": "- \(Vault.timeStamp(on: now))Z Something\\n"}
        ]}
        ```

        Rules:
        - "append" adds to the very END of the file. A note with headings usually
          means the end is the WRONG place — check before you reach for it
        - To file under a heading, use "replace": find the heading with the last
          line already under it, and put both back with your new line after them
        - Stamp a log entry with the current time above, as "- HH:MMZ text" — never
          invent a time and never copy the one in the example
        - A new note's frontmatter "id:" must be exactly \(idPlaceholder) — Ledge
          swaps in a real time-ordered identifier. Never invent one
        - Paths are relative to the vault root and must end in .md
        - "find" must match exactly once in that file; reproduce it byte for byte
        - There is no delete operation
        - If nothing needs changing, end with {"edits": []}

        The request:

        \(prompt)
        """
    }
}
