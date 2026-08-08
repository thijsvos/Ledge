#!/bin/bash
# Fake Claude Code CLI for runner tests — never burns tokens.
# Mimics `claude -p "<prompt>" --output-format stream-json` NDJSON output.
# Mode is selected via FAKE_CLAUDE_MODE: success (default) | edits | failure | garbage | slow
# `slow` sleeps FAKE_CLAUDE_SLEEP seconds (default 300) before finishing, to trip timeouts.
set -u

MODE="${FAKE_CLAUDE_MODE:-success}"
SESSION="fake-session-$$"

emit() { printf '%s\n' "$1"; }

emit_init() {
    emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$SESSION\",\"model\":\"fake\",\"tools\":[\"Read\",\"Write\",\"Edit\",\"Glob\",\"Grep\"]}"
}

case "$MODE" in
success)
    emit_init
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Done. Appended the task to today's daily note.\"}]}}"
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"$SESSION\",\"duration_ms\":1234,\"num_turns\":1,\"total_cost_usd\":0.0,\"result\":\"Done. Appended the task to today's daily note.\"}"
    ;;
edits)
    emit_init
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"daily/2026-08-08.md\",\"old_string\":\"a\",\"new_string\":\"b\"}}]}}"
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"notes/new-note.md\",\"content\":\"# New\"}}]}}"
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"daily/2026-08-08.md\",\"old_string\":\"b\",\"new_string\":\"c\"}},{\"type\":\"text\",\"text\":\"Edited two files.\"}]}}"
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"$SESSION\",\"duration_ms\":34210,\"num_turns\":4,\"total_cost_usd\":0.0,\"result\":\"Edited two files.\"}"
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
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"$SESSION\",\"duration_ms\":300000,\"num_turns\":1,\"total_cost_usd\":0.0,\"result\":\"finally done\"}"
    ;;
*)
    echo "fake-claude.sh: unknown FAKE_CLAUDE_MODE '$MODE'" >&2
    exit 2
    ;;
esac
