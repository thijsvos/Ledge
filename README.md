# Ledge

A macOS notch capture app for a [register](https://github.com/thijsvos/register)
markdown vault. Type into the notch and the thought is filed; prefix with `/`
and your locally installed Claude Code CLI does the note-work.

SwiftUI + AppKit, macOS 14.0+, MIT.

## What it does

- **Instant capture.** Plain text goes straight into today's daily note under
  `## Log`, written by Ledge itself — no AI, no tokens, no waiting. `.i` files
  to the inbox note instead.
- **Agent runs.** A `/` prefix hands the prompt to your `claude` binary as a
  child process. Ledge never calls an API and never touches your credentials;
  spawning the CLI you already have is the entire integration.
- **Ledge does the writing.** The agent runs read-only and replies with an
  *edit plan*. Ledge checks every path against the vault fence and applies it
  itself, keeping pre-images so `/undo` can reverse the last run exactly.

## Requirements

- macOS 14.0 or later
- [Claude Code](https://claude.com/claude-code) installed and logged in
- A register vault (any folder of markdown works)

## Build

```sh
make gen      # regenerate the Xcode project (after any project.yml change)
make build    # signed Debug build
make run      # build and launch
make test     # LedgeCore + app tests
make format   # swiftformat
make perf     # idle CPU / launch / memory budgets
```

### Signing

Debug builds are signed with a real Apple Development identity rather than
ad-hoc, because macOS keys folder-permission grants to the code signature and
an ad-hoc signature changes on every rebuild — otherwise it re-asks for vault
access after every `make run`.

Your team ID is not committed. Create a `Local.makefile` (gitignored):

```make
LEDGE_DEVELOPMENT_TEAM = ABCDE12345
```

Find yours with:

```sh
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject | sed 's/.*OU=\([^,]*\).*/\1/'
```

To build without signing at all — no Apple account needed, but macOS will
re-ask for folder access on each rebuild:

```sh
xcodebuild -scheme Ledge -configuration Debug -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build
```

## Safety

Enforced in code, with tests:

- Ledge never reads, stores or transmits anything under `~/.claude`, never
  calls an Anthropic endpoint, and has no API-key field. It only spawns your
  `claude` binary.
- `ANTHROPIC_API_KEY` is stripped from the child environment, so a key exported
  in your shell can never cause API billing.
- The agent gets `Read,Glob,Grep` and an explicit denylist covering `Write`,
  `Edit`, `Bash` and network tools. It cannot write; it proposes.
- Every path in a returned plan is resolved against the vault root — no
  traversal, no dotfiles, no non-markdown, capped at 20 edits and 1 MB.
- There is no delete operation.

## Layout

```
App/            AppKit lifecycle, window, controllers
UI/             SwiftUI views
Sources/LedgeCore/   all logic, no AppKit or SwiftUI — everything testable
  Capture/      routing, instant capture, native commands
  Plan/         edit plans: extract, validate, apply, undo
  Runner/       the claude child process and its stream
  Vault/        vault validation and the path fence
docs/           human QA checklist and results
```

`ledge-mvp-architecture-for-claude-code.md` is the spec; `CLAUDE.md` is the
contract for agents working on this repo.

## Licence

MIT — see [LICENSE](LICENSE).
