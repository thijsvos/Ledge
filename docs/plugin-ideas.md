# Ledge plugin/module ideas

Reference catalog, written 2026-08-09. Nothing here is built; the MVP scope fence
(§1/§10 of the architecture doc + CLAUDE.md) still stands. Each idea lists: the
pitch, how it shows up at the notch (collapsed / hover / peek / open), and a
feasibility grade with the mechanism. Grades: **easy · medium · hard · fragile**
(fragile = depends on private API or undocumented behavior that breaks across
macOS releases).

The companion plugin-system architecture (tiers, surfaces, arbiters, budget
rules) lives in the plan; the shortest version: built-in opt-in modules first,
a file-drop "ActivityBus" as the entire third-party story (data, never code),
and a permanent no to in-process plugin loading.

---

## 1. Media / Now Playing

### 1.1 Spotify + Apple Music controls — easy (AppleScript + push)
First-class controls and metadata for the two apps that legitimately expose
them. Both post distributed notifications on track/state change
(`com.spotify.client.PlaybackStateChanged`, `com.apple.Music.playerInfo`) —
pure push, zero polling — and both take AppleScript commands for
play/pause/next/prev/position. Notch: artwork thumbnail sliver while playing;
hover shows title/artist + transport buttons; track-change peek; open pane with
scrubber and shuffle/like. Spotify serves an artwork URL (needs network for
that one piece). **The recommended core of the media story.**

### 1.2 System-wide Now Playing — fragile (private MediaRemote)
Track info for anything playing anywhere. Requires Apple's private
MediaRemote framework, which is entitlement-locked since macOS 15.4; community
workarounds are in a cat-and-mouse cycle with Apple. Deliberately avoided —
1.1 is the reliable floor, and the browser gap is documented honestly.

### 1.3 Universal media keys — easy-medium (HID event synthesis)
Transport buttons that work on anything — including YouTube in a browser — by
synthesizing hardware media-key events, which macOS routes to the active
now-playing client. No metadata. Needs Accessibility permission.

### 1.4 Browser now-playing companion — medium-hard (WebExtension)
A small extension feeds tab media-session metadata to Ledge over native
messaging. Per-browser deliverables; Safari needs an app extension.

### 1.5 Audio output switcher — easy (CoreAudio, push)
Current output device on hover; open pane lists devices with per-device
volume; peek on automatic route change ("→ AirPods Pro").

### 1.6 Notch audio visualizer — medium (Core Audio process taps, macOS 14.4+)
Subtle EQ bars hugging the notch wings while audio plays. Must gate hard on
"audio actually playing" to protect the idle budget.

### 1.7 Live lyrics — medium-fragile (needs network + 1.1/1.2 position)
Synced lyric line under the notch. Sync drift and coverage gaps.

### 1.8 "Log this song" — easy (crossover with InstantCapture)
One tap writes the now-playing track into today's daily note — a listening log
inside the second brain. A pure-Ledge crossover generic notch apps can't do.

## 2. Vault / register-native (the moat)

### 2.1 Today's tasks + one-tap check-off — easy (FSEvents + markdown edit)
The unchecked `- [ ]` items from today's daily note live at the notch; tapping
writes the `x` into the markdown. register's watcher repaints within 100 ms —
two UIs synchronized through the filesystem. Collapsed: small count badge;
hover: top task; open: checklist; peek when the last one closes. **Probably
the single highest-value module.**

### 2.2 Inbox pressure gauge — easy (FSEvents + parse)
Badge with the count of unprocessed `000` inbox items, appearing only past a
threshold; open pane previews the oldest and offers "process with agent" (2.5).

### 2.3 Vault search (`?query`) — easy-medium (local grep/index)
Fuzzy filename + content search from the capture field; Enter opens the note,
⌘Enter appends a wiki-link to the daily note. No AI, no tokens. Extends the
existing prefix-routing pattern.

### 2.4 Scheduled agent runs ("morning digest") — easy-medium
At a chosen time (or first wake), Ledge silently runs a headless prompt like
`/daily-review` and peeks the result: "☀️ Digest ready — 4 tasks carried
over". Literally an AgentRun with a trigger instead of a keystroke;
NSBackgroundActivityScheduler keeps the zero-timer budget. **Only-Ledge #1.**

### 2.5 Agent inbox triage with undo — medium
One button: the agent files everything from the inbox into the right notes;
the peek offers undo backed by register's git checkpoints. Note: the agent
still never runs git (§2.3); Ledge invoking `git revert` itself is new surface
and needs a deliberate decision.

### 2.6 Task rollover on day change — easy
Unchecked tasks migrate into the new daily note automatically (native regex
move; agent-powered variant for smart merging). Peek on first expand of the
day: "↪ 3 tasks rolled over".

### 2.7 Frontmatter reminders — medium
`remind: 2026-08-12` in any note surfaces at the notch that day. Needs a
due-date index maintained on save + a wake-time check (schedulable, no poll).

### 2.8 Capture templates (`.t meeting`) — easy
Expands `vault/templates/<name>.md` into a new note or inline fields; template
picker reuses the SlashSuggestionList pattern.

### 2.9 Streaks & capture stats — easy
Capture streak and notes-per-week sparkline; one peek at first capture of the
day. Duolingo-grade retention for note-taking.

### 2.10 "On this day" resurfacing — easy
On first unlock of the morning, peek a snippet from a year-old daily note or a
random highlight. Agent-picked spaced-repetition variant: medium, costs a run.

### 2.11 Voice capture (hold-to-talk) — medium (SFSpeechRecognizer, on-device)
Hold the hotkey, speak, release — transcription lands in the daily note.
Mic permission; no network on Apple Silicon. Huge delight-per-effort.

### 2.12 Capture-anywhere — easy-medium (NSServices + drag target)
Select text anywhere → "Send to Ledge" with source-app/URL provenance; drag
text/files/images onto the notch to file into `vault/attachments/` with a link
appended to the daily note.

### 2.13 Screenshot → OCR → vault — medium (ScreenCaptureKit + Vision)
Grab a region, OCR it, append text + image link. Whiteboards become
searchable notes. Screen-recording permission.

### 2.14 Reading queue (`.r <url>`) — easy
Stash links into `reading.md`; notch shows queue count and serves the next
article. Title fetch needs network (optional).

### 2.15 Vault health monitor — medium
Debounced link-graph scan after agent runs; "⚠ 3 broken links" on hover with
a one-tap agent repair run.

### 2.16 Run diff quick-look — medium (git checkpoints or snapshots)
Hover a "✓ 2 files · 34s" peek to see per-file diffs of what the agent
actually changed. Converts trust-me into show-me for unattended runs.

### 2.17 Pinned focus note — easy
Pin `goals.md` or a project brief; first lines always one hover away.

## 3. Claude / AI-native

### 3.1 Claude Code session bus — easy (supported hooks + FSEvents) ⭐
A Ledge-provided hook script users add to any repo's Claude Code settings;
every terminal/IDE session then reports to the notch: second colored dot while
an external session runs, peeks on finish or "waiting for permission" with a
focus-that-terminal action. Pure push (hook writes JSON to a watched folder),
zero polling, never touches `~/.claude` auth. **The ActivityBus's killer app;
Only-Ledge #3.**

### 3.2 Session monitor via transcripts — medium-fragile
Zero-config fallback for 3.1 by watching `~/.claude/projects/**/*.jsonl`.
Undocumented format; also needs an explicit carve-out from the "don't touch
~/.claude" rule (transcripts aren't auth, but the boundary should be explicit).

### 3.3 Cost/usage meter — easy (existing RunHistory)
"3 runs · $0.00 · avg 28s" on hover; weekly digest peek. All-sessions
ccusage-style requires 3.2 (medium-fragile).

### 3.4 Queue manager — easy (existing ClaudeRunner surface)
See, reorder, and cancel the FIFO queue instead of the blind "Queued #n" peek.

### 3.5 Vault-defined slash commands — easy
Commands in the vault's `.claude/commands/` merged into the suggestion list
with a "vault" badge — the vault programs its own notch.

### 3.6 Per-run model/effort picker — easy
⌘Enter opens a small "run with…" chooser (model, effort, continue-last).

### 3.7 "Ask about my screen" (`/look`) — medium (ScreenCaptureKit)
Screenshot the frontmost window into the vault so the agent can Read it —
"summarize this PDF page into today's note". Stays inside the sanctioned CLI.

### 3.8 Multi-vault switcher — medium
Work + personal vaults; the capture chip shows which brain you're feeding;
per-vault run queues (the one-run-per-vault rule generalizes cleanly).

## 4. System status & peeks

### 4.1 Battery & charging — easy (IOKit power notifications)
Plug/unplug and threshold peeks; "⚡ 67% · full in 48 min"; thin amber edge
tint under 10%.

### 4.2 Volume/brightness HUD — augment easy, replace fragile
Device-change and mute peeks are easy. Suppressing Apple's center-screen bezel
requires the OSDUIHelper hack (private, breaks regularly) — if ever shipped,
behind an "advanced, may break" toggle only.

### 4.3 Mic/camera privacy pips — medium (CoreAudio/CoreMediaIO)
Orange/green "you are being seen/heard" pips beside the camera housing itself;
peek when a device turns on. Per-app attribution is fragile; device-level is
solid.

### 4.4 Bluetooth connect + battery — split
Connect/disconnect peeks: easy (IOBluetooth). AirPods battery levels:
fragile (BLE reverse-engineering, AirBuddy territory). Keyboard/mouse battery:
medium.

### 4.5 Focus/DND — medium-fragile
Reading Focus state means parsing an undocumented Assertions.json; toggling
via a user-installed Shortcut. Honest grade: setup friction + breakage risk.

### 4.6 VPN/network posture — medium (NWPathMonitor + SCDynamicStore, push)
SSID (needs Location permission now), VPN shield, captive-portal detection;
peek on VPN drop.

### 4.7 Thermal peek — easy (ProcessInfo.thermalState, push)
"Your Mac is throttling" the moment the state jumps, with the top process
named via a one-shot sample at event time.

### 4.8 Disk & Time Machine — medium
90 %-disk early warning checked on wake (not polled); backup completed/failed
peeks via tmutil.

### 4.9 Keep-awake pill — easy (IOPMAssertion)
One tap prevents sleep; faint dot while active; auto-expire peek.

## 5. Productivity

### 5.1 Clipboard history — medium, deliberately LAST
No pasteboard notification exists → 1 Hz changeCount polling (a declared
budget exception, suspended on lock/sleep), plus macOS 26 pasteboard-privacy
prompts for background readers. Honor concealed-type (password managers).

### 5.2 File shelf + AirDrop drop-zone — medium (drag APIs + NSSharingService)
Drag files to the notch to stage; drag out later; AirDrop straight from the
shelf; "file into vault attachments" twist is the Ledge-unique part.

### 5.3 Calendar next-meeting + Join link — medium (EventKit, push)
"Standup in 12 min" on hover; at T-2 a peek with the Zoom/Meet/Teams link
scraped from notes/location. Calendar permission; the T-2 alarm is a one-shot
scheduled wake, not a poll. Crossover: "create meeting note from template".

### 5.4 Timers & pomodoro — easy
`25m focus` in the capture field; progress arc hugs the notch; completion peek;
sessions can log to the daily note.

### 5.5 Inline calculator & unit conversion — easy
`= 4300*1.21` or `= 72 usd in eur` answered live under the field; Enter
captures "expression = result". Currency rates need network (cache daily).

### 5.6 World clocks — easy
"SF 07:42 · Tokyo 23:42" on hover; editable city list with daylight bars.

### 5.7 Screenshots shelf — easy (FSEvents on the screenshot folder) ⭐
Every new screenshot peeks instantly with a thumbnail — drag into Slack, OCR
into the vault (2.13), or trash. No more Desktop archaeology.

### 5.8 Apple Reminders quick-add — medium (EventKit + NSDataDetector)
`.rem buy milk tomorrow 9am`. Philosophical tension with "tasks live in the
vault" — position as a migration bridge.

## 6. Developer

### 6.1 Generic webhook / file-drop bus — easy ⭐ (superset of 3.1)
`echo '{"title":"Deploy done","level":"ok"}' > ~/…/activity/deploy.json` from
any script, cron, git hook, or CI relay → styled peek with optional action
URL. Ledge as the Mac's programmable ambient display; makes every other
integration user-buildable. Localhost HTTP listener variant: medium.

### 6.2 Git dirty/unpushed badges — easy (FSEvents on .git + on-event status)
"M3 ↑2" per pinned repo on hover; a peek when the lid is about to close with
unpushed work.

### 6.3 CI/PR watcher via gh — medium (subprocess + network)
"Watch this PR" — bounded polling with backoff for one PR at a time, peek on
green/red. Budget-pure alternative: a GitHub Actions final step posts to 6.1.

### 6.4 Docker events — easy-medium (docker events is a push stream)
Container crash/start/stop peeks; hover lists running containers. Degrades
gracefully when Docker isn't running.

### 6.5 Localhost port watcher — medium (budget tension)
No push API for sockets: check on hover (pull-on-demand) or poll only while an
explicit watch is armed. Best served via 6.1 instead.

### 6.6 Log watcher — easy (DispatchSource)
Point at a file + regex; matches become peeks; open pane tails recent matches.

### 6.7 Xcode/build status — via the bus only
Native DerivedData scraping is fragile; a post-build script dropping a bus
event is easy. Ship the recipe, not the scraper.

### 6.8 Tunnel URL grabber — medium
Peek the public ngrok/tunnel URL with a copy button when it comes up.

## 7. Communication & misc

### 7.1 Global mic mute — easy (CoreAudio)
Universal mute pill + hotkey that zeroes the input device across every meeting
app; red pip while muted; "talking while muted" detection via input metering
(active-only CPU): medium. Pairs with 4.3.

### 7.2 Unread badges — medium-fragile
Mail has a scripting dictionary (easy, but nudges Mail to launch); Slack and
Discord expose nothing — dock-badge scraping is fragile. Scope to Mail + bus.

### 7.3 Weather — medium (needs network)
Temperature on hover; peeks only when it matters ("🌧 rain in 20 min").
WeatherKit needs the paid developer entitlement; Open-Meteo is free. Fetch on
wake + hourly OS-coalesced background activity.

### 7.4 Notch pet — easy
A tiny cat sleeps on the notch; stirs on capture; mood tracks the streak
(2.9). Frames animate only on events — zero idle cost, maximum irrational
attachment.

### 7.5 Read-aloud — easy (AVSpeechSynthesizer)
"Read me my daily note" while making coffee; pause/speed on hover.

### 7.6 Countdown chips — easy
`countdown 2026-09-01 launch` sourced from a vault note (syncs across
machines); "T-23 days" on hover; milestone peeks.

---

## Shortlists

**Top 5 by delight × feasibility**
1. Today's tasks check-off (2.1) — used 20×/day; the moment Ledge becomes the vault's face.
2. Screenshots shelf (5.7) — trivial, universally loved; OCR→vault makes it Ledge's own.
3. Claude session bus / ActivityBus (3.1 + 6.1) — near-zero engineering, budget-pure, the agentic dashboard.
4. Calendar Join peek (5.3) — the most-thanked feature in this app category.
5. Spotify/Apple Music (1.1) — the seed request, on the two apps where it's reliable.

**Top 3 only-Ledge-can-do-this**
1. Scheduled agent digests + checkpoint-undo triage (2.4/2.5) — needs vault contract + hardened runner + ambient surface simultaneously.
2. Vault task/inbox peeks with markdown write-back (2.1/2.2/2.6) — task apps have no notch; notch apps have no vault.
3. Ambient monitor for every Claude Code session (3.1) — supported hooks + an always-idle status surface.

**First wave, if ever built:** module skeleton + ActivityBus together → media
(public-API scope) → calendar (first permission-gated module) → clipboard last
(polling + privacy friction). Amend §10's scope fence and CLAUDE.md in the
same commit.
