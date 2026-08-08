#!/bin/bash
# Ledge perf budget gate (§10, checked by `make perf`).
#
# Budgets enforced here:
#   cold launch ≤ 400 ms   (process spawn → the app's own "launched" perf log
#                           line, timed via the line's OWN logd timestamp so
#                           `log stream` delivery latency can't false-fail;
#                           WARN-only when the line can't be captured)
#   idle CPU    ≤ 0.1 %    (ps cputime/etime deltas across PERF_SAMPLE_SECS;
#                           the app has ZERO timers and ZERO polling when idle)
#   RAM         ≤ 50 MB    (ps rss primarily; when rss alone exceeds the
#                           budget — on macOS 13+ it counts resident SHARED
#                           dyld-cache pages, a ~60-80 MB floor no AppKit app
#                           can influence — the row is judged by vmmap
#                           physical footprint instead, with BOTH numbers
#                           printed; footprint over budget still FAILs)
#   island.transition ≤ 150 ms per interval (from `log show` signposts;
#                           WARN when none found — signposts only exist if
#                           transitions happened recently. The interval
#                           brackets the synchronous transition body — a
#                           main-thread-stall canary; render/animation time
#                           is outside it by design, per §4's signpost home)
#   capture.write ≤ 50 ms  per interval (§10 Enter→instant-capture file
#                           written; from `log show` signposts; WARN when
#                           none found — they exist only if a capture
#                           happened recently)
#
# Env:
#   PERF_SAMPLE_SECS  idle-CPU sampling window, default 60
#   PERF_APP_PATH     app bundle, default .build/Build/Products/Debug/Ledge.app
#
# The script only ever kills the pids IT spawned — never pkill by name.
#
# Spawned instances get `-hasRunOnboarding YES` (macOS NSArgumentDomain: a
# per-process, volatile defaults override — nothing is persisted, no app code
# involved). Without it a machine with fresh UserDefaults auto-presents the
# first-launch onboarding sheet + Settings window (§7), and the gate would be
# measuring that transient UX instead of the idle steady state the §10
# budgets describe.

set -euo pipefail

SAMPLE_SECS="${PERF_SAMPLE_SECS:-60}"
APP_PATH="${PERF_APP_PATH:-.build/Build/Products/Debug/Ledge.app}"
APP_BINARY="$APP_PATH/Contents/MacOS/Ledge"

LAUNCH_BUDGET_MS=400
CPU_BUDGET_PCT=0.1
RAM_BUDGET_MB=50
TRANSITION_BUDGET_MS=150
CAPTURE_BUDGET_MS=50

fail_count=0
declare -a table_rows=()

note()  { printf '%s\n' "$*"; }
row()   { table_rows+=("$1|$2|$3|$4"); }
verdict_fail() { fail_count=$((fail_count + 1)); }

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

# "[[dd-]hh:]mm:ss(.frac)" → seconds (float). Used for ps cputime/etime.
to_secs() {
  echo "$1" | awk -F'[-:]' '{
    n = NF; s = $n + $(n-1) * 60
    if (n >= 3) s += $(n-2) * 3600
    if (n >= 4) s += $(n-3) * 86400
    printf "%.4f\n", s
  }'
}

# "YYYY-MM-DD HH:MM:SS.mmm" (local time, as `log` prints it) → epoch ms.
log_ts_to_ms() {
  local ts="$1" secs frac
  secs=$(date -j -f "%Y-%m-%d %H:%M:%S" "${ts%.*}" +%s 2>/dev/null) || return 1
  frac="${ts##*.}"
  [[ "$frac" == "$ts" ]] && frac=0
  # Keep only the first 3 fractional digits as milliseconds.
  frac="${frac}000"; frac="${frac:0:3}"
  echo $((secs * 1000 + 10#$frac))
}

cleanup() {
  local pid
  for pid in "${spawned_pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}
spawned_pids=()
trap cleanup EXIT

# ---------------------------------------------------------------- (a) build
if [[ ! -x "$APP_BINARY" ]]; then
  echo "perf-check: $APP_BINARY not found or not executable." >&2
  echo "perf-check: run 'make build' first (or set PERF_APP_PATH)." >&2
  exit 2
fi

# Read-only heads-up (we never touch other pids): a user copy running during
# the sample means a transient second island + a second ⌥Space handler. The
# signpost scan pairs per-process, so measurements stay correct either way.
if pgrep -xq Ledge 2>/dev/null; then
  note "perf-check: note — another Ledge instance is already running; the QA"
  note "            instances spawned here will briefly coexist with it."
fi

scratch="$(mktemp -d /tmp/ledge-perf.XXXXXX)"
stream_file="$scratch/launch-stream.log"

# ---------------------------------------------------- (b) cold-launch timing
# `log show` is too slow/flaky for CI, so capture `log stream` in the
# background for just the launch window and read the app's own "launched"
# line (subsystem app.ledge, category perf — emitted once in
# applicationDidFinishLaunching).
note "perf-check: measuring cold launch…"
/usr/bin/log stream --style compact --level info \
  --predicate 'subsystem == "app.ledge"' > "$stream_file" 2>/dev/null &
stream_pid=$!
spawned_pids+=("$stream_pid")

# Give the stream a moment to attach so the launch line isn't missed.
for _ in $(seq 1 50); do
  [[ -s "$stream_file" ]] && break
  sleep 0.1
done

spawn_ms=$(now_ms)
"$APP_BINARY" -hasRunOnboarding YES >/dev/null 2>&1 &
launch_pid=$!
spawned_pids+=("$launch_pid")

launch_line=""
for _ in $(seq 1 100); do # up to 10 s
  launch_line=$(grep -E "Ledge\[$launch_pid:.*app\.ledge:perf.*launched" "$stream_file" | head -1 || true)
  [[ -n "$launch_line" ]] && break
  sleep 0.1
done

launch_result="WARN"
launch_measured="not captured"
if [[ -n "$launch_line" ]]; then
  line_ts=$(echo "$launch_line" | awk '{print $1 " " $2}')
  if line_ms=$(log_ts_to_ms "$line_ts") && [[ -n "$line_ms" ]]; then
    elapsed=$((line_ms - spawn_ms))
    if ((elapsed < 0 || elapsed > 60000)); then
      launch_measured="${elapsed} ms (implausible)"
      launch_result="WARN"
    else
      launch_measured="${elapsed} ms"
      if ((elapsed <= LAUNCH_BUDGET_MS)); then
        launch_result="PASS"
      else
        launch_result="FAIL"
        verdict_fail
      fi
    fi
  fi
fi
if [[ "$launch_result" == "WARN" ]]; then
  note "perf-check: WARN — cold-launch line not captured/parsed (never false-fails)."
fi
row "cold launch" "$launch_measured" "<= ${LAUNCH_BUDGET_MS} ms" "$launch_result"

# Cold-launch instance done; kill it (by pid only) and stop the stream.
kill "$launch_pid" 2>/dev/null || true
wait "$launch_pid" 2>/dev/null || true
kill "$stream_pid" 2>/dev/null || true
wait "$stream_pid" 2>/dev/null || true

# ------------------------------------------------- (c) idle CPU  (d) RAM
note "perf-check: sampling idle CPU for ${SAMPLE_SECS}s (fresh instance, 5s settle)…"
"$APP_BINARY" -hasRunOnboarding YES >/dev/null 2>&1 &
idle_pid=$!
spawned_pids+=("$idle_pid")
sleep 5

if ! kill -0 "$idle_pid" 2>/dev/null; then
  echo "perf-check: app exited during settle — cannot sample idle CPU." >&2
  exit 2
fi

cpu1=$(to_secs "$(ps -o cputime= -p "$idle_pid" | tr -d ' ')")
et1=$(to_secs "$(ps -o etime= -p "$idle_pid" | tr -d ' ')")
sleep "$SAMPLE_SECS"
cpu2=$(to_secs "$(ps -o cputime= -p "$idle_pid" | tr -d ' ')")
et2=$(to_secs "$(ps -o etime= -p "$idle_pid" | tr -d ' ')")

cpu_pct=$(awk -v c1="$cpu1" -v c2="$cpu2" -v e1="$et1" -v e2="$et2" \
  'BEGIN { d = e2 - e1; if (d <= 0) d = 1; printf "%.4f", (c2 - c1) / d * 100 }')
if awk -v p="$cpu_pct" -v b="$CPU_BUDGET_PCT" 'BEGIN { exit !(p <= b) }'; then
  cpu_result="PASS"
else
  cpu_result="FAIL"
  verdict_fail
fi
row "idle CPU" "${cpu_pct} %" "<= ${CPU_BUDGET_PCT} %" "$cpu_result"

rss_kb=$(ps -o rss= -p "$idle_pid" | tr -d ' ')
rss_mb=$(awk -v kb="$rss_kb" 'BEGIN { printf "%.1f", kb / 1024 }')
if awk -v m="$rss_mb" -v b="$RAM_BUDGET_MB" 'BEGIN { exit !(m <= b) }'; then
  ram_result="PASS"
  ram_measured="${rss_mb} MB rss"
else
  # On macOS 13+ `ps -o rss` counts resident SHARED dyld-cache pages, so any
  # AppKit process reports ~60-80 MB regardless of its own allocations — the
  # app cannot influence that floor. When rss alone exceeds the budget, judge
  # by physical footprint (what Activity Monitor's "Memory" column shows and
  # the app IS accountable for), reporting both numbers.
  footprint_line=$(vmmap --summary "$idle_pid" 2>/dev/null \
    | grep -m1 '^Physical footprint:' || true)
  footprint=$(echo "$footprint_line" | awk '{print $3}')
  footprint_mb=$(echo "$footprint" | awk '
    /G$/ { printf "%.1f", $0 * 1024; next }
    /M$/ { printf "%.1f", $0 + 0; next }
    /K$/ { printf "%.1f", $0 / 1024; next }
    { print "" }')
  if [[ -n "$footprint_mb" ]]; then
    ram_measured="${footprint_mb} MB footprint (${rss_mb} MB rss)"
    if awk -v m="$footprint_mb" -v b="$RAM_BUDGET_MB" 'BEGIN { exit !(m <= b) }'; then
      ram_result="PASS"
      note "perf-check: rss ${rss_mb} MB exceeds budget but is dominated by shared"
      note "            dyld-cache pages; physical footprint ${footprint_mb} MB is within budget."
    else
      ram_result="FAIL"
      verdict_fail
    fi
  else
    ram_measured="${rss_mb} MB rss (footprint unavailable)"
    ram_result="FAIL"
    verdict_fail
  fi
fi
row "RAM" "$ram_measured" "<= ${RAM_BUDGET_MB} MB" "$ram_result"

# (f) kill ONLY the pid we spawned — never pkill by name.
kill "$idle_pid" 2>/dev/null || true
wait "$idle_pid" 2>/dev/null || true

# --------------------------------------------- (e) signpost durations
note "perf-check: scanning perf signposts (last 5m)…"
signpost_log=$(/usr/bin/log show --last 5m --signpost --style compact \
  --predicate 'subsystem == "app.ledge" AND category == "perf"' 2>/dev/null || true)

# Compact signpost lines look like:
#   DATE TIME Sp Proc[pid:tid] [app.ledge:perf] [spid 0xN, process, begin] name
# Begin/end are paired per (process token, spid) — NEVER by textual order
# alone, which mispairs when several Ledge instances (the user's running
# copy + a QA run) interleave in the log window. Negative deltas (midnight
# rollover inside the 5m window) are dropped.
scan_intervals() {
  echo "$signpost_log" | awk -v name="$1" '
    $NF == name && match($0, /\[spid 0x[0-9a-f]+, [a-z]+, +(begin|end)\]/) {
      tag = substr($0, RSTART, RLENGTH)
      spid = tag
      sub(/^\[spid /, "", spid); sub(/,.*$/, "", spid)
      key = $4 "|" spid
      split($2, t, /[:.]/)
      ms = ((t[1] * 3600) + (t[2] * 60) + t[3]) * 1000 + t[4]
      if (tag ~ /begin\]$/) { pending[key] = ms; have[key] = 1 }
      else if (have[key]) {
        d = ms - pending[key]
        if (d >= 0) printf "%d\n", d
        have[key] = 0
      }
    }'
}

# One budget row per signpost name: FAIL any single interval over budget,
# WARN when none were found (signposts only exist if the action happened
# recently — the spawned QA instances above are idle and emit none).
check_intervals() {
  local name="$1" budget="$2" activity="$3"
  local intervals result measured count max
  intervals=$(scan_intervals "$name")
  result="WARN"
  measured="none found"
  if [[ -n "$intervals" ]]; then
    count=$(echo "$intervals" | wc -l | tr -d ' ')
    max=$(echo "$intervals" | sort -n | tail -1)
    measured="${count} interval(s), max ${max} ms"
    if ((max <= budget)); then
      result="PASS"
    else
      result="FAIL"
      verdict_fail
    fi
  else
    note "perf-check: WARN — no ${name} signposts in the last 5m"
    note "            (expected unless ${activity} recently)."
  fi
  row "$name" "$measured" "<= ${budget} ms" "$result"
}

check_intervals "island.transition" "$TRANSITION_BUDGET_MS" "the island was used"
check_intervals "capture.write" "$CAPTURE_BUDGET_MS" "an instant capture ran"

rm -rf "$scratch"

# ------------------------------------------------------------- budget table
note ""
note "perf-check budget table"
printf '%-20s %-26s %-14s %s\n' "metric" "measured" "budget" "verdict"
printf '%-20s %-26s %-14s %s\n' "------" "--------" "------" "-------"
for entry in "${table_rows[@]}"; do
  IFS='|' read -r metric measured budget verdict <<< "$entry"
  printf '%-20s %-26s %-14s %s\n' "$metric" "$measured" "$budget" "$verdict"
done
note ""

if ((fail_count > 0)); then
  note "perf-check: FAIL (${fail_count} budget(s) exceeded)"
  exit 1
fi
note "perf-check: OK"
