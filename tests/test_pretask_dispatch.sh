#!/usr/bin/env bash
# tests/test_pretask_dispatch.sh — P1.5-2 pre-task.sh ディスパッチャの単体テスト
# 1つでも check が exit1 を返すと deny JSON、全通過で無出力（allow）を検証
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# 強制レイヤー一式を temp にコピー
mkdir -p "$T/.claude/sprint/hooks" "$T/.claude/sprint/policy/checks" "$T/sprint" \
         "$T/.claude/worktrees/task-01/src"
cp "$ROOT_REPO/.claude/sprint/hooks/_guard.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/hooks/pre-task.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/policy/checks/"*.sh "$T/.claude/sprint/policy/checks/"
: > "$T/sprint/SPRINT.md"

PRE="$T/.claude/sprint/hooks/pre-task.sh"

# 全規則を満たす baseline state（RUNNING・契約合意・進行中タスク・RED・失敗0・EXECUTE）
baseline_state() {
  cat > "$T/sprint/state.json" <<'EOF'
{
  "phase": "EXECUTE",
  "run_state": "RUNNING",
  "contract": {"agreed": true},
  "tasks": {"task-01": {"status":"IN_PROGRESS","worktree":".claude/worktrees/task-01","tdd_phase":"RED","failure_count":0}},
  "resume_hint": {"current_task": "task-01"}
}
EOF
}

# pre-task.sh を JSON 入力で実行し、deny かどうかを返す（deny=1, allow=0）
dispatch() {
  local input="$1"
  local out
  out=$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$T" bash "$PRE" 2>/dev/null)
  if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "deny"
  elif [ -z "$out" ]; then
    echo "allow"
  else
    echo "other:$out"
  fi
}

expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

echo "=== test_pretask_dispatch.sh ==="

# allow: baseline で worktree 内 src 書込 → 全通過
baseline_state
IN='{"tool_name":"Write","tool_input":{"file_path":"'"$T"'/.claude/worktrees/task-01/src/foo.ts"}}'
expect "[allow] 全規則充足 → 無出力(allow)" "allow" "$(dispatch "$IN")"

# deny: contract.agreed=false（R1 違反）
baseline_state
jq '.contract.agreed=false' "$T/sprint/state.json" > "$T/s.tmp" && mv "$T/s.tmp" "$T/sprint/state.json"
expect "[deny] R1 違反（契約未合意）→ deny" "deny" "$(dispatch "$IN")"

# deny: 非アクティブ（run_state=OFF）でも... → guard が no-op → allow（隔離優先）
baseline_state
jq '.run_state="OFF"' "$T/sprint/state.json" > "$T/s.tmp" && mv "$T/s.tmp" "$T/sprint/state.json"
expect "[allow] run_state=OFF は guard で no-op → allow" "allow" "$(dispatch "$IN")"

# deny: 破損 state.json かつ RUNNING を保てない → guard no-op（allow）。
# 破損だが run_state だけ読めるケースは作れないため、ディスパッチャの fail-closed は
# 「RUNNING だが他フィールド欠落」で検証する（下記 e2e で担保）。

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
