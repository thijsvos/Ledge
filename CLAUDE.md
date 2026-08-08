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
- Headless runs: allowedTools exactly "Read,Write,Edit,Glob,Grep", permission-mode
  acceptEdits, max-turns 6, cwd = vault. Never widen without explicit instruction.
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
