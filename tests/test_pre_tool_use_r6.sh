#!/usr/bin/env bash
# T-A.13: pre-tool-use-bash-v2.sh の R6（worker は git 直接操作禁止）強制を検証
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HOOK="$REPO_ROOT/.claude/sprint/hooks/pre-tool-use-bash-v2.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK"; exit 1; }

fail=0
pass=0

run_case() {
  local name="$1" input="$2" expected_decision="$3"
  local out decision reason
  out=$(echo "$input" | bash "$HOOK" 2>&1 || true)
  decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
  if [ "$decision" = "$expected_decision" ]; then
    pass=$((pass+1)); echo "  PASS: $name (decision=$decision)"
  else
    fail=$((fail+1)); echo "  FAIL: $name (expected=$expected_decision, got=$decision)"
    echo "    output: $out"
  fi
  # deny の場合は理由文に "R6" を含むことを確認
  if [ "$expected_decision" = "deny" ]; then
    reason=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)
    if echo "$reason" | grep -q "R6"; then
      pass=$((pass+1)); echo "  PASS: $name reason mentions R6"
    else
      fail=$((fail+1)); echo "  FAIL: $name reason missing R6 (reason='$reason')"
    fi
  fi
}

run_case "worker + git add" \
  '{"subagent_type":"worker","tool_name":"Bash","tool_input":{"command":"git add ."}}' \
  "deny"

run_case "worker + git push" \
  '{"subagent_type":"worker","tool_name":"Bash","tool_input":{"command":"git push"}}' \
  "deny"

run_case "worker + chain && git status" \
  '{"subagent_type":"worker","tool_name":"Bash","tool_input":{"command":"echo hi && git status"}}' \
  "deny"

run_case "repo-mgr + git commit" \
  '{"subagent_type":"repo-mgr","tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}' \
  "allow"

run_case "worker + pytest" \
  '{"subagent_type":"worker","tool_name":"Bash","tool_input":{"command":"pytest"}}' \
  "allow"

echo "Total: pass=$pass fail=$fail"
if [ "$fail" = "0" ]; then
  echo "PASS: test_pre_tool_use_r6"
  exit 0
else
  echo "FAIL: test_pre_tool_use_r6 ($fail failures)"
  exit 1
fi
