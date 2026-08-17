# Ledge MVP — architecture & build plan (hand this file to Claude Code)

This document is self-contained: it is the complete specification for the MVP. Read it fully before writing code. Where it conflicts with anything else, this file and `CLAUDE.md` win.

---

## 1. What the MVP is

**Ledge** is a native macOS notch app ("dynamic island") whose single job in this MVP is: **capture thoughts and delegate note-work to Claude Code against a `register` vault, without the user ever opening a terminal.**

`register` (github.com/thijsvos/register) is a file-native second brain: the vault is a plain folder of markdown, its UI watches the filesystem and repaints agent edits within 100 ms, and `register init` writes a `CLAUDE.md` agent contract into the vault. Consequence for us: **Ledge never talks to register.** Writing markdown files into the vault folder IS the integration. No API, no sync, no MCP.

The interaction, end to end:

1. User presses ⌥Space (or clicks the notch). The island expands to a single capture field in ≤150 ms.
2. **Plain text** → InstantCapture: Ledge itself appends it to today's daily note (or the inbox) in ≤50 ms, zero AI, zero tokens. Island collapses on Enter.
3. **Text starting with `/`** → AgentRun: Ledge spawns the user's locally installed Claude Code CLI in headless mode inside the vault directory. The island collapses immediately; a small status dot shows a run is live; a banner peek confirms completion ("✓ 2 files · 34s") or failure.
4. Failure or stuck run → peek offers "Open in Terminal", which resumes the exact session in a real terminal. The terminal is the escape hatch, never the requirement.

**MVP scope (in):** notch window + geometry, collapsed/hover/open/peek state machine, capture field, InstantCapture, ClaudeRunner with queueing and result peeks, settings (vault path, hotkey, launch at login, claude binary path), onboarding checks.

**MVP scope (out, staged in §10):** Now Playing, clipboard history, file shelf/AirDrop, weather, calendar, volume/battery banners, multi-display fake islands, Sparkle updates. Do not build any of these, even partially, unless explicitly instructed.

---

## 2. Non-negotiable constraints (safety & auth)

These exist to keep the user's Claude subscription unambiguously within Anthropic's sanctioned usage (official CLI only) and to keep unattended agent runs safe. Violating any of these is a bug of the highest severity.

1. **Official CLI only.** Ledge invokes the user's installed `claude` binary as a child process. Ledge must NEVER read, copy, store, or transmit OAuth tokens, credentials files, or anything under `~/.claude` related to auth; never call Anthropic HTTP endpoints; never embed an API key or offer a field to enter one.
2. **Environment sanitization.** The child process environment is the inherited environment with `ANTHROPIC_API_KEY` removed, so a key exported in the user's shell can never cause accidental API billing. Assert this in a unit test.
3. **Read-only agent; Ledge performs every write.** Headless runs use `--allowedTools "Read,Glob,Grep"` plus an explicit `--disallowedTools "Write,Edit,MultiEdit,NotebookEdit,Bash,WebSearch,WebFetch"` — no writing, no command execution, no network. The agent explores the vault and returns an **edit plan** (`Plan/EditPlan.swift`); Ledge checks it against the vault fence (`Vault.resolve(relativePath:)`) and applies it (`Plan/EditPlanApplier.swift`). `--max-turns 6` still bounds the exploration.

   This *narrows* the old rule rather than replacing it. Previously the blast radius was "some markdown files in one folder changed" because Claude's flags said so; now it is that because Ledge's own code refuses anything else, with tests against it — paths outside the vault, dotfiles (a plan must never author `.claude/commands/*.md`), non-`.md` files, more than 20 edits, or more than 1 MB of new material. There is no delete operation, and every run keeps pre-images so `/undo` can reverse it.

   **Never ask the agent for something it cannot know.** It has no clock, no entropy, and no memory of the vault's conventions beyond what it can read — so asked for such a value it fabricates a plausible-looking one. Human QA (2026-08-16) found all three failure modes at once: entries stamped `00:00Z`, and note IDs like `01KZQBARTENDER0ICONISSUE18` that are neither valid ULIDs nor time-ordered. So `PlanContract` states the UTC date and time, and `Support/ULID.swift` mints every new note's identifier — the agent writes a `{{ulid}}` placeholder and `PlanContract.fillingIdentifiers` swaps in the real one before validation, so the byte caps and pre-images stay honest. The same rule governs the worked example in the contract: whatever literal it shows comes back verbatim, so it must be generated, not hardcoded.
4. **One run at a time per vault** (serialized queue). Concurrent agent edits race each other and the vault's git checkpointing.
5. **Working directory is always the vault**, never `~`, never `/`. Refuse to run if the configured vault path doesn't exist or isn't a directory.

---

## 3. Repository layout & toolchain

```
Ledge/
  project.yml               # XcodeGen is the only project definition; .xcodeproj is gitignored
  Makefile                  # gen · build · run · test · format · perf
  CLAUDE.md                 # §8 — commit verbatim
  App/                      # AppDelegate, main entry, status item, onboarding sheet
  Sources/LedgeCore/        # local SPM package: ALL logic, no AppKit windows — fully testable
    Geometry/  StateMachine/  Capture/  Runner/  Vault/  Support/
  UI/                       # SwiftUI: IslandView, NotchShape, CaptureView, PeekView, Settings
  Tests/LedgeCoreTests/
  Tests/fixtures/
    fake-claude.sh          # emits canned NDJSON; used by all runner tests (never burns tokens)
    vault/                  # miniature register-shaped vault for capture tests
    live-probe.ndjson       # captured in Phase 0 from the real CLI
  scripts/perf-check.sh
```

* Targets: `Ledge.app` (macOS 14.0 deployment — never raise it; `LSUIElement: true`; Debug signing `CODE_SIGN_IDENTITY: "-"`) and `LedgeCoreTests`. `LedgeCore` is a local Swift package so `swift test` works headlessly.
* Only third-party dependency allowed: `sindresorhus/KeyboardShortcuts`. Login item via native `SMAppService`.
* Swift 6 language mode if painless, else 5 mode with strict concurrency. All UI `@MainActor`; `ClaudeRunner` and stores are actors. `@Observable` for state, no Combine.
* Makefile: `gen` (xcodegen), `build` (`xcodebuild -scheme Ledge -configuration Debug -derivedDataPath .build build`), `run` (build + open app), `test` (`swift test --package-path Sources/LedgeCore` then app-level `xcodebuild test`), `format` (swiftformat), `perf` (scripts/perf-check.sh).

---

## 4. The notch window (condensed spec — implement exactly)

**Geometry** (`Geometry/NotchGeometry.swift`, pure functions, unit-tested):

* Notched built-in display ⇔ `NSScreen.safeAreaInsets.top > 0`. Flanking areas: `screen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
* Notch rect: `x = topLeft.maxX`, `width = frame.width − topLeft.width − topRight.width`, `height = safeAreaInsets.top`, anchored to `frame.maxY`.
* No notch (MVP fallback): centered fake island, width 190 pt, height `max(frame.maxY − visibleFrame.maxY, 24)`.
* Recompute on `NSApplication.didChangeScreenParametersNotification` and wake. Test fixtures: 14" MBP, 16" MBP, 13" Air, no-notch display.

**Window** (`NotchWindow: NSPanel`):

```swift
styleMask: [.borderless, .nonactivatingPanel]
level: .statusBar
collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
isOpaque = false; backgroundColor = .clear; hasShadow = false   // shadow ON only when open
hidesOnDeactivate = false; isMovableByWindowBackground = false
```

* Window frame is always the expanded maximum (notch width + 560 pt wide, 200 pt tall, top-anchored); the black shape animates inside it. Never resize the NSWindow during animation.
* SwiftUI `contentShape` = the black shape only, so clicks beside the island fall through. If pass-through proves unreliable in Phase 1 testing, shrink the window frame in collapsed state instead (documented fallback).
* Focus discipline: the panel becomes key only while the capture field is visible; resign key + `orderBack` semantics on collapse. Typing in other apps must never be intercepted while collapsed.

**State machine** (`StateMachine/IslandState.swift`):

```swift
enum IslandState: Equatable {
  case collapsed            // pixel-identical to the physical notch
  case hover                // grown ~10pt, affordance hint
  case open                 // capture field visible, panel is key
  case running(RunHandle)   // collapsed + animated status dot at notch edge
  case peek(PeekContent)    // banner for 2.5s: success / failure / queued info
}
```

All mutations go through `IslandController.transition(to:)` (`@MainActor`), which emits `os_signpost` intervals (subsystem `app.ledge`, category `perf`). One shared spring: `.spring(response: 0.18, dampingFraction: 0.85)`. Hover debounce 40 ms. (Both retuned in human QA on 2026-08-17, from `0.32/0.78` and 80 ms. The transition body itself measures 0.02–0.15 ms, so everything a user perceives as "not instant" lives in these two numbers and nowhere else.) Esc / click-outside (local + global monitor) collapses; `running` and `peek` may overlay while user works — they never steal focus.

---

## 5. Capture pipeline

**Router** (`Capture/CaptureRouter.swift`, pure, tested): input string →
* starts with `/` → `.agent(prompt: String(dropFirst))`
* starts with `.i ` → `.instant(target: .inbox, text: rest)`
* otherwise → `.instant(target: .daily, text: input)`

**InstantCapture** (`Capture/InstantCapture.swift`):

* Daily target: `vault/daily/YYYY-MM-DD.md`, date in **UTC** (register's convention). If missing, create it from `vault/templates/daily.md` when that exists, else create with a minimal `# YYYY-MM-DD` header. Write `- HH:MMZ <text>` (UTC time) at the end of the note's `## Log` section, or at end-of-file when it has none. (Amended in human QA on 2026-08-17: end-of-file append was the original rule, but a register daily template ends with `## Tasks`, so every captured thought was filed as a task. Same placement rule the agent gets from `PlanContract` — a note with headings means the end of the file is the wrong place.)
* Inbox target: the note whose filename begins with `000` at the vault root (glob `000*.md`); if absent, fall back to the daily note and say so in the peek.
* Atomic append (open, write, close); total Enter→file-on-disk budget 50 ms. register's own watcher repaints its UI within 100 ms — Ledge does nothing further.
* Unit tests run against `Tests/fixtures/vault/` covering: UTC date rollover, template-based creation, inbox glob, missing-inbox fallback, unicode text.

**AgentRun** → hand the prompt to ClaudeRunner (§6). The island transitions `open → running` immediately on Enter; the user is never left waiting at the notch.

---

## 6. ClaudeRunner (the heart of the MVP)

`Runner/ClaudeRunner.swift` — an `actor` owning a FIFO queue (one live run per vault).

**Binary resolution** (GUI apps do NOT inherit shell PATH — this is a classic failure):
1. Settings override path, if set and executable.
2. Probe common locations: `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude`, `~/.claude/local/claude`, npm global bin.
3. Once per launch, fallback: `/bin/zsh -lc 'command -v claude'` and cache the result.
4. Nothing found → onboarding state "Claude Code not found" with a link to the install docs. Never bundle or download the CLI.

**Invocation** (working directory = vault; environment = inherited minus `ANTHROPIC_API_KEY`):

```
claude -p "<edit-plan contract + prompt>" \
  --output-format stream-json \
  --verbose \
  --allowedTools "Read,Glob,Grep" \
  --disallowedTools "Write,Edit,MultiEdit,NotebookEdit,Bash,WebSearch,WebFetch" \
  --max-turns 6 \
  --strict-mcp-config
```

`--permission-mode acceptEdits` is deliberately absent: with no edit tools there is nothing to accept, and leaving it would be a lie in the argv. Live-probed against claude 2.1.226 — exit 0, no prompt, no stall, `Glob`/`Read` only.

The prompt is the user's request wrapped in the edit-plan contract (`Plan/PlanContract.swift`), which also states today's date in **UTC** — the CLI injects its own *local* date, which names the wrong daily note for anyone west of UTC after 00:00Z. The contract travels in the prompt rather than in the vault's `CLAUDE.md` so Ledge works against a vault with no agent config at all.

Append `--resume <sessionID>` only when the user tapped "continue last" (last session ID stored per vault in UserDefaults). Default is a fresh session per request — the vault plus its `CLAUDE.md` contract is the memory; fresh sessions are faster and can't accumulate drift.

**Stream parsing** (`Runner/StreamParser.swift`): the CLI emits newline-delimited JSON. Representative shapes — **verify against the live probe captured in Phase 0 and code the parser against observed reality, tolerantly ignoring unknown types and fields**:

```json
{"type":"system","subtype":"init","session_id":"…"}
{"type":"assistant","message":{"content":[{"type":"text","text":"…"},{"type":"tool_use","name":"Edit","input":{"file_path":"…"}}]}}
{"type":"result","subtype":"success","session_id":"…","duration_ms":34210,"num_turns":4,"total_cost_usd":0.0,"result":"…"}
```

Extract: `session_id` (persist), assistant text (kept for a detail view), duration, and final result text. Parser is unit-tested against both `live-probe.ndjson` and `fake-claude.sh` output.

"N files edited" comes from what Ledge actually wrote (`AppliedPlan.filesChanged`), not from Write/Edit `tool_use` blocks — those tools are denied now, so the stream can no longer report them and the count would always be zero.

**Lifecycle & failure:**
* Timeout: 120 s wall clock → SIGTERM, then SIGKILL after 5 s → failure peek.
* Non-zero exit / malformed stream → failure peek showing the stderr tail (last 3 lines).
* Failure peek actions: **Open in Terminal** — write `/tmp/ledge-resume-<uuid>.command` containing `cd '<vault>' && claude --resume '<sessionID>'`, `chmod +x`, open via `NSWorkspace` (launches Terminal running it) — and **Copy command**.
* Queued prompts while a run is live show a `peek(.queued(n))`; queue max 5, reject beyond with a peek.
* App quit with a live run: SIGTERM the child, persist nothing.

**Testing without tokens:** every runner test injects `fake-claude.sh` as the binary (it echoes canned NDJSON streams: success, edit-heavy, failure, garbage, slow). The real CLI is touched only by Phase 0's probe and by the human's live QA.

---

## 7. Settings, onboarding, vault contract

* **Settings window** (SwiftUI `Settings` scene): vault folder picker; global hotkey (KeyboardShortcuts, default ⌥Space); launch at login (`SMAppService.mainApp`); claude binary override; "continue last session" toggle for `/` runs (default off).
* **Onboarding checks** (sheet on first launch, re-checkable from Settings): claude binary found? vault path set and exists? vault contains a `CLAUDE.md`? If the vault has git, recommend enabling register's checkpoints (`.register/config.json` → `{"checkpoints": true}`) — Ledge only recommends, never edits the vault's config.
* **Vault contract addendum**: onboarding offers a one-click "Add headless clause to vault CLAUDE.md", appending exactly:

```markdown
## Headless invocations (Ledge)
When run non-interactively (claude -p): never ask questions. Make the smallest
conforming edit, record any assumption inline in the affected note as
"assumption: …", and do not run shell, git, or register commands.
```

If the user declines, everything still works; runs are just slightly less predictable.

---

## 8. CLAUDE.md for THIS repo (commit verbatim at repo root)

```markdown
# Ledge (MVP)

Native macOS notch capture app for a register markdown vault, delegating note-work
to the user's locally installed Claude Code CLI. SwiftUI + AppKit, macOS 14.0+
(never raise), MIT.

## Commands
- make gen    — regenerate the Xcode project after ANY project.yml or file change
- make build  — must pass before every commit
- make test   — LedgeCore + app tests; must pass before every commit
- make format — swiftformat; run before every commit
- make perf   — budget check (idle CPU, signpost durations)

## Hard rules (safety)
- NEVER read, copy, store, or transmit auth tokens or anything auth-related under
  ~/.claude; NEVER call Anthropic HTTP endpoints; NEVER add an API-key field.
  The ONLY integration is spawning the user's `claude` binary.
- Child process env must strip ANTHROPIC_API_KEY (test asserts this).
- Headless runs: allowedTools exactly "Read,Glob,Grep", disallowedTools exactly
  "Write,Edit,MultiEdit,NotebookEdit,Bash,WebSearch,WebFetch", max-turns 6,
  cwd = vault. Never widen without explicit instruction.
- The agent NEVER writes. It returns an edit plan; LedgeCore checks every path
  with Vault.resolve(relativePath:) and applies it (Sources/LedgeCore/Plan).
  Never hand a write tool back to the agent. There is no delete operation.
- One run per vault at a time. Runner tests use Tests/fixtures/fake-claude.sh,
  never the real CLI.

## Architecture rules
- Sources/LedgeCore = all logic, no NSWindow/SwiftUI imports; everything testable.
- IslandController.transition(to:) is the ONLY IslandState mutation point; every
  transition emits an os_signpost (subsystem app.ledge, category perf).
- UI on @MainActor; ClaudeRunner and stores are actors; no DispatchQueue.main.async.
- No force unwraps outside tests; no try!; os.Logger categories: island, capture,
  runner, vault, perf.
- MVP scope is fenced by §1/§10 of the architecture doc — do not build staged
  features (media, clipboard, shelf, weather, calendar) even partially.

## Definition of done, every task
Builds clean · tests pass · swiftformat clean · --dump-geometry and
--render-preview still work · descriptive commit.
```

---

## 9. Build phases (run each in a fresh Claude Code session; commit at every green checkpoint)

**Phase 0 — Scaffold + CLI probe.**
Create the repo per §3: project.yml, Makefile, CLAUDE.md (§8 verbatim), LedgeCore with a placeholder test, swiftformat config, MIT LICENSE, .gitignore, fixtures directory with `fake-claude.sh` (success/failure/slow modes) and the miniature register-shaped vault. Then probe the real CLI: run `claude --help`, then `claude -p "Reply with exactly: ok" --output-format stream-json` from a throwaway directory, saving stdout verbatim to `Tests/fixtures/live-probe.ndjson`. If `claude` is not installed or not authenticated, stop and tell the human — do not fake the fixture.
*Acceptance:* clean clone → `make gen build test` green; both fixtures committed.
*Human:* be present for the probe (it uses your login); skim the NDJSON once.

**Phase 1 — Window, geometry, state machine.**
Implement §4 fully, plus launch flags `--dump-geometry` (per-screen JSON, exit) and `--render-preview <collapsed|hover|open> <out.png>` (offscreen `ImageRenderer`, exit). Unit tests for geometry fixtures and every legal/illegal state transition.
*Acceptance:* tests green; `--dump-geometry` sane; three previews render.
*Human QA (the quality gate for the whole product):* collapsed state pixel-invisible against the real notch; hover/open feel instant; Esc and click-outside collapse; typing in other apps is never intercepted; nothing steals focus.

**Phase 2 — Capture field + InstantCapture.**
Implement §5 against the fixture vault, wire the capture UI (single field, subtle `/`-hint, target chip showing daily/inbox), Enter collapses immediately with a success peek.
*Acceptance:* all §5 unit tests green, including UTC rollover and template creation.
*Human QA:* point Settings at your real vault, capture a thought, watch it appear in register's UI in under a blink; confirm `.i ` lands in note 000.

**Phase 3 — ClaudeRunner + peeks + escape hatch.**
Implement §6: resolution, sanitized spawn, stream parser (coded against live-probe + fake fixtures), queue, timeout, running-dot, success/failure peeks, Open-in-Terminal resume, Copy command, env-sanitization test.
*Acceptance:* all runner tests green against `fake-claude.sh` variants; parser test green against `live-probe.ndjson`.
*Human QA:* `/append a task "test ledge" to today's daily note` — watch the dot, get the ✓ peek, see the edit in register; `export ANTHROPIC_API_KEY=sk-test` in your shell first and confirm the run still uses your subscription login; kill `claude` mid-run and confirm the failure peek + terminal resume works.

**Phase 4 — Settings, onboarding, polish, perf gate.**
Implement §7; empty/error states everywhere; reduced-motion support (`accessibilityDisplayShouldReduceMotion` → cross-fades); `scripts/perf-check.sh` sampling 60 s idle CPU and grepping signpost durations from `log show --last 5m --predicate 'subsystem == "app.ledge"'`, failing over budget.
*Acceptance:* `make perf` green; onboarding correctly detects missing binary / vault / CLAUDE.md when simulated.
*Human QA:* fresh-eyes run-through from a clean UserDefaults state; reboot for the login item.

---

## 10. Budgets & staged backlog

**Budgets (hard, checked by `make perf`):** hotkey→field visible ≤150 ms; Enter→instant-capture file written ≤50 ms; idle CPU ≤0.1 % (the MVP has zero timers and zero polling when idle — keep it that way); RAM ≤50 MB; cold launch ≤400 ms.

**Staged (do not build):** Now Playing (private MediaRemote — has its own gotchas), clipboard history, file shelf + AirDrop, calendar/weather, volume/battery peeks, ActivityBus file protocol, multi-display fake islands, Sparkle, notarized releases. A separate full-product architecture document covers these; the MVP's ModuleKit-free simplicity is intentional — refactor toward modules only when the first staged feature actually lands.
