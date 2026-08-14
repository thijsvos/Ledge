#!/bin/bash
# Fake Claude Code CLI for runner tests — never burns tokens.
# Mimics `claude -p "<prompt>" --output-format stream-json` NDJSON output.
# Mode is selected via FAKE_CLAUDE_MODE: success (default) | edits | failure | garbage | slow
#   | envcheck | errorresult | argvcheck | plan | planfenced | planbad
# `slow` sleeps FAKE_CLAUDE_SLEEP seconds (default 300) before finishing, to trip timeouts.
# `envcheck` fails (exit 3) if ANTHROPIC_API_KEY leaked into this environment,
# else emits the success stream — proves the spawner sanitized the child env.
# `argvcheck` writes its own argv NUL-separated to FAKE_CLAUDE_ARGV_OUT, so a test
# can assert what the CHILD received rather than only what the argv builder returned.
# NUL-separated because the prompt legitimately contains newlines.
# `plan`/`planfenced`/`planbad` return edit plans as the final message (§2.3): bare,
# wrapped in prose and a fence, and one that tries to escape the vault.
# Result events carry is_error, matching live-probe.ndjson (claude 2.1.226).
set -u

MODE="${FAKE_CLAUDE_MODE:-success}"
SESSION="fake-session-$$"

emit() { printf '%s\n' "$1"; }

emit_init() {
    emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$SESSION\",\"model\":\"fake\",\"tools\":[\"Read\",\"Write\",\"Edit\",\"Glob\",\"Grep\"]}"
}

emit_success_stream() {
    emit_init
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Done. Appended the task to today's daily note.\"}]}}"
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$SESSION\",\"duration_ms\":1234,\"num_turns\":1,\"total_cost_usd\":0.0,\"result\":\"Done. Appended the task to today's daily note.\"}"
}

# $1 is the final message, already escaped for embedding in a JSON string.
emit_result_with() {
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$SESSION\",\"duration_ms\":1200,\"num_turns\":2,\"total_cost_usd\":0.0,\"result\":\"$1\"}"
}

case "$MODE" in
success)
    emit_success_stream
    ;;
edits)
    emit_init
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"daily/2026-08-08.md\",\"old_string\":\"a\",\"new_string\":\"b\"}}]}}"
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"notes/new-note.md\",\"content\":\"# New\"}}]}}"
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"daily/2026-08-08.md\",\"old_string\":\"b\",\"new_string\":\"c\"}},{\"type\":\"text\",\"text\":\"Edited two files.\"}]}}"
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$SESSION\",\"duration_ms\":34210,\"num_turns\":4,\"total_cost_usd\":0.0,\"result\":\"Edited two files.\"}"
    ;;
failure)
    emit_init
    echo "Error: fake transport failure" >&2
    echo "Caused by: FAKE_CLAUDE_MODE=failure" >&2
    echo "Giving up after 1 attempt" >&2
    exit 1
    ;;
garbage)
    emit "this is not json at all"
    emit "{\"type\":\"assistant\",\"message\":{BROKEN"
    emit "42"
    ;;
slow)
    emit_init
    sleep "${FAKE_CLAUDE_SLEEP:-300}"
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$SESSION\",\"duration_ms\":300000,\"num_turns\":1,\"total_cost_usd\":0.0,\"result\":\"finally done\"}"
    ;;
envcheck)
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "ANTHROPIC_API_KEY leaked into child env" >&2
        exit 3
    fi
    emit_success_stream
    ;;
errorresult)
    # Error result event on a ZERO exit (e.g. the CLI's error_max_turns):
    # the runner must classify this as errorResult, never "exit 0".
    emit_init
    emit "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"session_id\":\"$SESSION\",\"duration_ms\":9999,\"num_turns\":6,\"total_cost_usd\":0.0,\"result\":\"Reached max turns without finishing\"}"
    ;;
argvcheck)
    if [ -n "${FAKE_CLAUDE_ARGV_OUT:-}" ]; then
        printf '%s\0' "$@" > "$FAKE_CLAUDE_ARGV_OUT"
    fi
    emit_success_stream
    ;;
plan)
    emit_init
    emit_result_with '{\"edits\":[{\"op\":\"append\",\"path\":\"daily/2026-08-07.md\",\"text\":\"- 09:15Z from the fake agent\\n\"}]}'
    ;;
planfenced)
    emit_init
    emit_result_with 'Filed it under today.\n\n```json\n{\"edits\":[{\"op\":\"create\",\"path\":\"notes/fenced.md\",\"content\":\"# Fenced\"}]}\n```'
    ;;
planbad)
    emit_init
    emit_result_with '```json\n{\"edits\":[{\"op\":\"create\",\"path\":\"../escape.md\",\"content\":\"x\"}]}\n```'
    ;;
*)
    echo "fake-claude.sh: unknown FAKE_CLAUDE_MODE '$MODE'" >&2
    exit 2
    ;;
esac
