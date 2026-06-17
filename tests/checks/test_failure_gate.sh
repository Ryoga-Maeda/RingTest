#!/usr/bin/env bash
# tests/checks/test_failure_gate.sh — R4 failure_gate.sh の単体テスト
# PT1-4: 帰属を current_task からパス逆引き（FILE→worktree→task、無ければ CWD）へ。
# 並列で片方が3回失敗しても、無関係なもう片方はブロックされない。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT_REPO/.claude/sprint/policy/checks/failure_gate.sh"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sprint" "$T/.claude/sprint/policy/checks" \
  "$T/.claude/worktrees/task-01/src" "$T/.claude/worktrees/task-02/src"
cp "$ROOT_REPO/.claude/sprint/policy/checks/_task_from_path.sh" "$T/.claude/sprint/policy/checks/"
export ROOT="$T" STATE_FILE="$T/sprint/state.json"

# run <file> [tool] [cwd]
run() { FILE="$1" TOOL="${2:-Write}" CWD="${3:-}" bash "$CHECK" >/dev/null 2>&1; echo $?; }
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected exit=$e got $a)"; FAIL=$((FAIL+1)); fi; }

# task-01 の failure_count を指定。worktree 付き。
state_fc() {
  jq -nc --arg ph "$1" --argjson fc "$2" \
    '{phase:$ph,tasks:{"task-01":{status:"IN_PROGRESS",failure_count:$fc,worktree:".claude/worktrees/task-01"}}}' > "$STATE_FILE"
}
WT01="$T/.claude/worktrees/task-01/src/foo.ts"
WT02="$T/.claude/worktrees/task-02/src/bar.ts"

echo "=== test_failure_gate.sh (R4) ==="

# 正常: failure_count=2 → allow
state_fc "EXECUTE" 2
expect "[正常] failure_count=2 → allow" 0 "$(run "$WT01")"

# 違反: failure_count=3 → deny
state_fc "EXECUTE" 3
expect "[違反] failure_count=3 → deny" 1 "$(run "$WT01")"
state_fc "EXECUTE" 5
expect "[違反] failure_count=5 → deny" 1 "$(run "$WT01")"

# 制御面除外（C-1）: failure_count>=3 でも sprint/ 配下は allow（ESCALATION 遷移を許す）
state_fc "EXECUTE" 3
expect "[除外] failure_count=3 でも state.json 書込は allow" 0 "$(run "$T/sprint/state.json")"
expect "[除外] failure_count=3 でも sprint/ 配下は allow" 0 "$(run "$T/sprint/checkpoint.md")"

# 例外: ESCALATION フェーズなら failure_count=3 でも allow
state_fc "ESCALATION" 3
expect "[例外] ESCALATION 中は allow" 0 "$(run "$WT01")"

# PT1-4: 並列で片方が3回失敗 → 無関係なもう片方はブロックされない
jq -nc '{phase:"EXECUTE",tasks:{
  "task-01":{status:"IN_PROGRESS",failure_count:3,worktree:".claude/worktrees/task-01"},
  "task-02":{status:"IN_PROGRESS",failure_count:0,worktree:".claude/worktrees/task-02"}
}}' > "$STATE_FILE"
expect "[PT1-4] task-01(fc=3) の worktree 書込 → deny" 1 "$(run "$WT01")"
expect "[PT1-4] task-02(fc=0) の worktree 書込 → allow（無関係はブロックしない）" 0 "$(run "$WT02")"

# PT1-4: 書込先の無いコマンドでも CWD=worktree なら帰属して判定
state_fc "EXECUTE" 3
expect "[PT1-4] FILE 無し＋CWD=task-01(fc=3) → deny" 1 "$(run "" Bash "$T/.claude/worktrees/task-01")"

# 対象外: worktree 外でタスク特定不能 → pass（他チェックに委ねる）
state_fc "EXECUTE" 3
expect "[対象外] worktree 外でタスク特定不能 → allow" 0 "$(run "$T/somewhere/foo.ts")"
expect "[対象外] FILE 空＋CWD 無し → allow" 0 "$(run "")"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
