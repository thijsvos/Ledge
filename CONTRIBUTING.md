# Contributing

Ledge is small and deliberately narrow. The most useful contribution is a bug
report from real use — especially anything where the app writes something you
did not expect.

## Before you start

Two documents define what this project will and will not do:

- **`CLAUDE.md`** — the hard rules. The safety constraints there are not
  negotiable; a change that relaxes one will be declined regardless of merit.
- **`ledge-mvp-architecture-for-claude-code.md`** — the spec, and the reasoning.
  `§1` and `§10` fence the scope: features listed as staged (media, clipboard,
  shelf, weather, calendar) are deliberately not built, not even partially.

If a change contradicts either, the document wins — or the document changes in
the same commit, with the reasoning written down.

## Setup

```sh
brew install xcodegen swiftformat
make gen && make test
```

`make test` needs no Apple account: `Sources/LedgeCore` is a standalone SPM
package. Building the app is what needs signing — see the README for the
`Local.makefile` step, or build unsigned.

## Definition of done

Every change, without exception:

```sh
make format   # swiftformat
make build    # must pass
make test     # must pass
make perf     # idle CPU / launch / memory budgets — local only, not in CI
```

Plus: `--dump-geometry` and `--render-preview` still work, and a descriptive
commit message.

## What good looks like here

**Logic goes in `Sources/LedgeCore`.** No AppKit, no SwiftUI, everything
testable. `App/` and `UI/` are the thin layer that owns instances and renders.
This is not style preference — the App layer has no test target, so a rule that
lives there is a rule nothing can verify. Several bugs found in QA existed for
exactly that reason.

**Comments explain why.** The house style is prose that states the constraint
being protected and what breaks if you get it wrong, not a restatement of the
signature. Structured `- Parameter:` blocks are not used.

**Tests pin the reason, not just the behaviour.** A test whose name and comment
explain what would go wrong is worth more than three that assert mechanics.

**Never ask the agent for something it cannot know.** It has no clock and no
entropy, so it fabricates. Ledge supplies the date, the time and every note's
ULID. Whatever literal the worked example in `PlanContract` shows will come back
verbatim, so it must be generated rather than hardcoded — three separate bugs
came from ignoring this.

## Reporting a bug

Include the vault state before and after (`git diff` if your vault is a repo),
what the peek said, and anything from Console.app filtered to subsystem
`app.ledge`. Security issues go through [SECURITY.md](SECURITY.md) instead.
