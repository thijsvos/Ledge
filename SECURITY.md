# Security

Ledge runs unattended agent work against a folder of your notes. That only
works if the boundaries are real, so they are enforced in code and covered by
tests rather than promised in prose. This document states them plainly.

## Reporting a vulnerability

Please open a [security advisory](https://github.com/thijsvos/Ledge/security/advisories/new)
rather than a public issue. I will acknowledge within a week.

If a report shows any of the guarantees below can be broken, treat it as the
highest severity — those guarantees are the product.

## What Ledge will never do

**Never touch your credentials.** Ledge does not read, copy, store or transmit
anything under `~/.claude` — not tokens, not credential files, nothing
auth-related. It never calls an Anthropic HTTP endpoint and has no field to
enter an API key. Spawning the `claude` binary you already have is the entire
integration.

**Never cause API billing.** `ANTHROPIC_API_KEY` is stripped from the child
process environment, so a key exported in your shell cannot be picked up and
charged. A unit test asserts the child cannot see it, and it was verified end
to end during QA: Ledge was launched from a shell with the variable set,
confirmed still present in Ledge's own environment, and the run completed
normally on the subscription login.

**Never let the agent write.** The agent is invoked with
`--allowedTools "Read,Glob,Grep"` plus an explicit
`--disallowedTools "Write,Edit,MultiEdit,NotebookEdit,Bash,WebSearch,WebFetch"`.
It cannot write files, run commands or reach the network. It explores and
returns an *edit plan*; Ledge validates and applies it.

Worth stating precisely, because QA established it: **the allowlist alone is not
the fence.** A live probe showed a tool absent from `--allowedTools` still being
used. The denylist is what actually holds, which is why it names the dangerous
tools explicitly instead of relying on omission.

**Never write outside the vault.** Every path in a returned plan is resolved
against the vault root before anything is written. Refused outright: absolute
paths, `~` paths, any `..` component, any hidden component (so a plan can never
author `.claude/commands/*.md`), anything that is not `.md`, and symlinks
resolving outside the vault. A plan is capped at 20 edits and 1 MB of new
material, and is validated in full before any of it is applied.

**Never delete.** There is no delete operation. The worst a malformed or
hostile plan can do is add markdown, and every run keeps pre-images so `/undo`
reverses it exactly.

**Never run with a dangerous working directory.** The child's working directory
is always the vault, never `/` and never your home folder.

## Scope

Ledge is a local macOS app. It has no server, no telemetry, no network
listener, and one third-party dependency
([KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), pinned
to an exact version because it installs a global hotkey monitor).

The `claude` CLI it spawns is Anthropic's and out of scope here — report issues
with it to Anthropic.

## Where the rules live

- `CLAUDE.md` — the rules, stated as constraints
- `§2` of `ledge-mvp-architecture-for-claude-code.md` — the reasoning
- `Sources/LedgeCore/Vault/VaultPath.swift` — the path fence
- `Sources/LedgeCore/Plan/` — validation and application
- `Sources/LedgeCore/Runner/ClaudeRunner.swift` — the invocation and env sanitising
