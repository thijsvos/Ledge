# Ledge plugin/module system — full plan

## Context

Ledge's MVP is one-function by design. The goal is an opt-in plugin system so users enable features à la carte (media controls, calendar, task peeks, …) without ever compromising the three things that make Ledge trustworthy: the §2 safety story around the Claude child process, the §10 idle budget (zero timers, zero polling, ≤0.1% CPU), and the notch illusion (collapsed = pixel-invisible). The detailed idea catalog lives in `docs/plugin-ideas.md`; this is the system that hosts those ideas. §10 mandates: build the module skeleton only together with its first real module, never speculatively.

## Tiering — who gets to extend Ledge, and how

- **Tier 0 — built-in modules (build first).** Compiled into Ledge, all OFF by default, toggled in a Settings "Modules" tab. Logic in `Sources/LedgeCore/Modules/<Name>/` (AppKit-free, headlessly tested), OS adapters in `App/ModuleAdapters/`, views in `UI/Modules/`. No notarization/sandbox/§2 implications: the binary stays exactly as auditable as today.
- **Tier 1 — ActivityBus (build second; the ENTIRE third-party story for now).** A watched drop-folder (`~/Library/Application Support/Ledge/activity/`): any script, cron job, git hook, or CI writes one small JSON file → Ledge renders a peek and consumes the file. Schema `{v, source, title, detail?, glyph?, action?, ttl?}` with a whitelisted SF-Symbol set and whitelisted actions (`open-url`, `reveal-path` — never "run command"). Third parties contribute **data, never code**: §2-clean by construction, budget-clean via FSEvents (watcher exists only while the module is enabled). v2 adds state files (e.g. an overwritten `now-playing.json` drives a sliver) — sliver surface for scripts, still zero code loading.
- **Tier 2 — out-of-process helper executables (design for, don't build).** User-installed helpers speaking versioned JSON over stdio (language-server style) if interactive third-party surfaces ever have real demand. Process isolation keeps §2 promises statements about Ledge. Parked until demand exists.
- **Tier X — in-process dylib/bundle loading: never.** Requires `disable-library-validation` (weakens the hardened runtime), makes §2 unverifiable (in-process code could re-spawn claude with widened tools or read `~/.claude`), and makes the idle budget unenforceable. Permanently rejected.

## Surfaces a module can contribute

1. **Collapsed slivers** — the scarce resource. Exactly two slots (leading/trailing), single owner per slot, content constrained by type to `glyph | thumbnail | dot` (no text, notch-height-sized). Priority classes: core > critical > transient > ambient; ties broken by user drag-order in Settings; preempted slivers restored when the winner releases. Core reserves trailing whenever an agent run is live — the running dot is non-negotiable. Idle with no slivers stays pixel-identical to the bare notch; `--render-preview` gains sliver fixtures so the QA gate stays mechanical.
2. **Hover ornaments** — only for the current sliver owner ("the sliver, expanded" — e.g. transport buttons). Keeps hover from becoming a junk drawer; arbitration is already answered by slot ownership.
3. **Peeks** — the cheapest surface: ONE new case `PeekContent.module(ModulePeek{moduleID, glyph, title, detail?, action?})`. Expiry/overlay/no-focus-steal semantics inherited. A `PeekArbiter` is the only module path to `transition(to: .peek)`: core peeks outrank module peeks; module peeks never interrupt `.open` (deferred until idle, ambient ones dropped past their TTL); per-module token-bucket rate limiting + coalescing ("3 events from clipboard"). Pure, unit-testable policy in LedgeCore.
4. **Open-state panes** — modal replacements of the capture UI reached explicitly via a /command or sliver tap, Esc returns. No tabs, no persistent chrome. Mechanism: observable side-models rendered while `IslandState` stays `.open` — the `/resume` picker is the proven precedent.
5. **Native /commands** — `NativeCommand` becomes the core set inside a command registry. Precedence: core native > module command > Claude-catalog slash-restoration. Existing subtleties (exact-match-only, single-match Enter completion, space-escapes-to-Claude) become registry-level rules re-pinned by the existing tests. Module commands declared in the manifest so Settings can show conflicts.
6. **Settings section** — "Modules" tab: master enable list + drag-to-reorder (the sliver tiebreak), plus an optional per-module settings view.

**State-machine sovereignty:** modules never touch `IslandController` directly. `IslandState` gains ZERO new cases; the only payload change is `PeekContent.module`. Only the PeekArbiter calls `transition(to:)` on modules' behalf; slivers/panes go through side-models that never transition. The 5×5 matrix, its exhaustive tests, and CLAUDE.md's single-mutation-point rule survive untouched.

## Budget governance (the §10 guarantee)

1. **Context-owned event sources.** Modules cannot create observers/timers; they request sources from their `ModuleContext` (`events.workspace(…)`, `.distributed(name:)`, `.fileWatch(url:)`, `.scheduledWake(at:)`). The context tracks every token → `deactivate()` force-drains everything even for a buggy module, and each delivered event runs inside a `module.<id>.event` signpost — per-module cost accounting for free.
2. **Disabled = not allocated.** The registry instantiates only enabled modules. Invariant test: empty enablement set ⇒ zero module objects, behavior byte-identical to today.
3. **Manifest-declared budget classes.** `pushOnly` (default, only class most modules may use) vs `declaredPolling(pct, reason)`. The one honest polling case: clipboard (`changeCount` @1 Hz, suspended on lock/sleep — macOS has no pasteboard notification). Calendar's T-2 alarm is a re-armed one-shot `Task.sleep` (the peek-expiry pattern), not polling.
4. **`make perf` module matrix.** Baseline (all off) keeps the hard ≤0.1% gate. `PERF_MODULES=… scripts/perf-check.sh` asserts baseline + sum of declared allowances and gates `module.<id>.event` signpost durations (≤5 ms on main).

## Lifecycle & API shape (LedgeCore, pure)

```
ModuleManifest { id, name, summary, surfaces: Set<Surface>, budget: BudgetClass, commands: [ModuleCommandSpec] }
protocol LedgeModule (@MainActor, AnyObject) { static manifest; init(context:); activate(); deactivate() }
ModuleContext { events, peeks, sliver, pane, defaults (all keys "module.<id>."), logger (category "module.<id>") }
```

Launch → registry reads enabled set → instantiate + activate. Toggle off → deactivate → context drains → instance released; toggle on → fresh instance (no suspend/resume state to get wrong). Wake handling: registry re-arms scheduled wakes on the existing `didWakeNotification` observer. Modules test headlessly against injected fake `AsyncStream`s — the `fake-claude.sh` philosophy applied to event sources.

## Risks (decided up front)

- **MediaRemote (system-wide Now Playing): dead end** — entitlement-locked since macOS 15.4. Ship Spotify/Apple Music via their push distributed notifications + AppleScript; document the browser gap; no private-API path even behind a toggle.
- **Clipboard: last.** Inherent polling + macOS 26 pasteboard-privacy prompts for background readers; design consent onboarding; honor concealed-type.
- **Calendar: first TCC-gated module** (EventKit full-access prompt, usage string).
- **Sandbox/notarization:** Tier 0/1 change nothing. Ledge can't adopt App Sandbox anyway (spawns user's claude into an arbitrary vault cwd), but in-process loading would additionally poison the hardened runtime — another reason for Tier X = never.
- **Scope fence:** when the skeleton lands, amend §10 + CLAUDE.md in the same commit, or future agent sessions fight the fence.

## Key decisions

| # | Decision | Call |
|---|---|---|
| D1 | Third-party model | Data via ActivityBus, never in-process code; out-of-process executables designed-for but unbuilt |
| D2 | State machine | Zero new IslandState cases; arbiters + side-models; one PeekContent payload addition |
| D3 | Collapsed real estate | Two slots, single owner, priority classes, user-ordered tiebreak; running dot always wins |
| D4 | Budget | Context-vended push sources only; manifest budget classes; per-module perf matrix |
| D5 | Media scope | Public APIs only (Spotify/Music); no MediaRemote ever |

## Build order (when the day comes)

1. ModuleKit skeleton + **ActivityBus** together (pathfinder: pure push, no permissions, smallest surface, instant script-user value).
2. **Media** (public-API scope) — forces SliverArbiter + preview fixtures.
3. **Calendar** — first TCC-gated module + scheduled-wake pattern.
4. **Clipboard** — last; forces `declaredPolling` machinery to be real.
5. ActivityBus v2 (state files → slivers); reassess Tier 2 demand (expected: none).

## Files that change when built

`Sources/LedgeCore/StateMachine/StateMachine.swift` (PeekContent.module + arbiter seam) · `Sources/LedgeCore/Capture/NativeCommand.swift` (registry refactor) · `App/NotchWindowController.swift` (composition root wiring) · `UI/IslandView.swift` (sliver/pane rendering via side-model pattern) · `UI/SettingsView.swift` (Modules tab) · `scripts/perf-check.sh` (module matrix) · new `Sources/LedgeCore/Modules/`, `App/ModuleAdapters/`, `UI/Modules/` · amend architecture doc §10 + CLAUDE.md.

## Verification (per module wave, when built)

All existing gates (`make gen build test format`, previews, `--dump-geometry`) + the perf module matrix (baseline unchanged with modules off; enabled set within declared budgets) + registry invariant tests (disabled = zero allocations) + arbiter policy tests (peek precedence, rate limits, sliver preemption/restore) + the Phase-1-style human QA: idle with no slivers pixel-identical to the notch.

## Status

**Ideas only — nothing is being built now.** The catalog is committed to paper at `docs/plugin-ideas.md` (file created, not yet git-committed); this plan is the reference for whenever a first wave is greenlit.
