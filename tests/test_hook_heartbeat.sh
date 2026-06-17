#!/usr/bin/env bash
# tests/test_hook_heartbeat.sh
# FR-3: session-start.sh / post-task.sh がフック発火ごとに hook_heartbeat を更新し、
#       非アクティブ（OFF）では更新しない（_guard による no-op）ことを検証する。
set -uo pipefail
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SPRINT_DIR="$T/sprint"; HOOKS_DIR="$T/.claude/sprint/hooks"
mkdir -p "$SPRINT_DIR" "$HOOKS_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for h in _guard.sh _state.sh session-start.sh post-task.sh; do
  [ -f "$SCRIPT_DIR/.claude/sprint/hooks/$h" ] && cp "$SCRIPT_DIR/.claude/sprint/hooks/$h" "$HOOKS_DIR/"
done
check(){ local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "PASS: $d"; PASS=$((PASS+1)); else echo "FAIL: $d (expected='$e' got='$a')"; FAIL=$((FAIL+1)); fi; }

mk_state() { echo '{"sprint_id":"s","phase":"EXECUTE","run_state":"RUNNING","resilience":{"consecutive_tool_failures":0},"resume_hint":{"current_task":"t1","read_first":[]},"tasks":{}}' > "$SPRINT_DIR/state.json"; }

echo "=== test_hook_heartbeat.sh（FR-3）==="

# session-start が hook_heartbeat を更新
mk_state
CLAUDE_PROJECT_DIR="$T" bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1
check "session-start が hook_heartbeat を記録" "yes" "$(jq -e '.hook_heartbeat' "$SPRINT_DIR/state.json" >/dev/null 2>&1 && echo yes || echo no)"

# post-task が hook_heartbeat を更新
mk_state
echo '{"tool_input":{"command":"echo hi"},"tool_response":{"exit_code":0}}' | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS_DIR/post-task.sh" >/dev/null 2>&1
check "post-task が hook_heartbeat を記録" "yes" "$(jq -e '.hook_heartbeat' "$SPRINT_DIR/state.json" >/dev/null 2>&1 && echo yes || echo no)"

# OFF（非アクティブ）では更新しない（_guard で no-op）
echo '{"sprint_id":"s","run_state":"OFF","tasks":{}}' > "$SPRINT_DIR/state.json"
echo '{"tool_input":{"command":"echo hi"},"tool_response":{"exit_code":0}}' | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS_DIR/post-task.sh" >/dev/null 2>&1
check "OFF では hook_heartbeat を記録しない（no-op）" "no" "$(jq -e '.hook_heartbeat' "$SPRINT_DIR/state.json" >/dev/null 2>&1 && echo yes || echo no)"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
