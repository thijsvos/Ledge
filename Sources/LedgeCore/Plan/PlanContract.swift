// What Ledge asks the agent for (§2.3).
//
// The contract travels in the prompt rather than in the vault's CLAUDE.md for
// two reasons: Ledge then works against a vault with no agent config in it at
// all, and the same wording will carry to other CLIs unchanged.
//
// The UTC date is injected deliberately. register's convention is that all
// dates are UTC (see Vault.dayStamp), but a CLI injects its own *local* date
// into context — so an agent left to work it out names the wrong daily note
// for anyone west of UTC after 00:00Z.

import Foundation

public enum PlanContract {
    /// Wraps the user's prompt in the edit-plan contract. The user's own words
    /// come last: they are what the agent should act on, and recency helps.
    public static func wrap(prompt: String, now: Date = Date()) -> String {
        """
        You are filing a note into a markdown vault. Today is \(Vault.dayStamp(on: now)) \
        (UTC — this vault dates everything in UTC).

        You have read-only access. Explore with Read, Glob and Grep, then report what \
        should change. Do NOT try to write, edit or create files: you have no tools for \
        it and Ledge performs every write itself.

        End your reply with exactly one fenced json block holding an edit plan:

        ```json
        {"edits": [
          {"op": "append", "path": "daily/\(Vault.dayStamp(on: now)).md", "text": "- 09:15Z Something\\n"},
          {"op": "create", "path": "notes/new-thing.md", "content": "# New thing\\n"},
          {"op": "replace", "path": "notes/index.md", "find": "exact existing text", "with": "replacement"}
        ]}
        ```

        Rules:
        - Paths are relative to the vault root and must end in .md
        - "find" must match exactly once in that file; reproduce it byte for byte
        - There is no delete operation
        - If nothing needs changing, end with {"edits": []}

        The request:

        \(prompt)
        """
    }
}
