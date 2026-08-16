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

import Foundation

public enum PlanContract {
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
          {"op": "append", "path": "daily/\(Vault.dayStamp(on: now)).md", "text": "- \(Vault.timeStamp(on: now))Z Something\\n"},
          {"op": "create", "path": "notes/new-thing.md", "content": "# New thing\\n"},
          {"op": "replace", "path": "notes/index.md", "find": "exact existing text", "with": "replacement"}
        ]}
        ```

        Rules:
        - Stamp a log entry with the current time above, as "- HH:MMZ text" — never
          invent a time and never copy the one in the example
        - Paths are relative to the vault root and must end in .md
        - "find" must match exactly once in that file; reproduce it byte for byte
        - There is no delete operation
        - If nothing needs changing, end with {"edits": []}

        The request:

        \(prompt)
        """
    }
}
