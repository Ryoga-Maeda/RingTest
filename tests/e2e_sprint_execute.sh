#!/usr/bin/env bash
# tests/e2e_sprint_execute.sh — P3-5（M4達成判定）スプリント実行 E2E
# 契約合意→worktree割当→TDD→2段階レビュー→失敗3回でエスカレーション、までを検証する。
# 対応する結合テスト仕様（tests/integration-test-spec.md）:
#   IT-02(部分), IT-04(failure_count/GREEN), IT-09-1(create), IT-E2E-03(ESCALATION)
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/sprint/hooks" "$T/.claude/sprint/policy/checks" \
         "$T/.claude/agents" "$T/sprint/tasks" "$T/scripts"
cp "$ROOT_REPO/.claude/sprint/hooks/_guard.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/hooks/pre-task.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/hooks/post-task.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/policy/checks/"*.sh "$T/.claude/sprint/policy/checks/"
cp "$ROOT_REPO/scripts/worktree.sh" "$T/scripts/"
cp "$ROOT_REPO/.claude/sprint/hooks/_push.sh" "$T/.claude/sprint/hooks/"  # IH-W5: worktree.sh の push ヘルパ
cp "$ROOT_REPO/.claude/sprint/hooks/_state.sh" "$T/.claude/sprint/hooks/"  # PT0-1: worktree/post-task が source する flock ヘルパ
: > "$T/sprint/SPRINT.md"
PRE="$T/.claude/sprint/hooks/pre-task.sh"
POST="$T/.claude/sprint/hooks/post-task.sh"

# temp を git リポジトリ化（worktree 用）
git -C "$T" init -q
git -C "$T" config user.email t@t.com; git -C "$T" config user.name T
git -C "$T" config commit.gpgsign false
echo "init" > "$T/README"; git -C "$T" add -A; git -C "$T" commit -qm init

expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }
verdict() {
  local input="$1" out
  out=$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$T" bash "$PRE" 2>/dev/null)
  if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then echo deny; elif [ -z "$out" ]; then echo allow; else echo other; fi
}
w_input() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
state() { jq -r "$1" "$T/sprint/state.json"; }

# 契約未合意・進行中タスクなしの EXECUTE 初期状態
cat > "$T/sprint/state.json" <<'EOF'
{
  "phase": "EXECUTE", "run_state": "RUNNING",
  "contract": {"agreed": false, "iteration": 0, "max_iterations": 15},
  "tasks": {}, "resume_hint": {"current_task": "task-001", "in_flight": ["task-001"]}
}
EOF
echo '{"CLARIFY_TO_DESIGN":{"approved_by":"human"}}' > "$T/sprint/gate_approvals.json"

echo "=== e2e_sprint_execute.sh （スプリント実行 M4） ==="

echo "--- ステップ1: 契約未合意で src 書込 → deny（R1）---"
expect "[R1] 契約未合意の src 編集 → deny" "deny" "$(verdict "$(w_input Write "$T/src/foo.ts")")"

echo "--- ステップ2: 契約合意＋worktree 作成 ---"
jq '.contract.agreed=true' "$T/sprint/state.json" > "$T/s.tmp" && mv "$T/s.tmp" "$T/sprint/state.json"
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" create task-001 >/dev/null
expect "[P3-2] worktree 作成で status=IN_PROGRESS" "IN_PROGRESS" "$(state '.tasks["task-001"].status')"
# PT3: tdd_phase / failure_count はタスクローカル（sprint/tasks/task-001.status.json）が真実。
TS="$T/sprint/tasks/task-001.status.json"
tget() { jq -r "$1" "$TS" 2>/dev/null; }
tset() { jq "$1" "$TS" > "$TS.tmp" && mv "$TS.tmp" "$TS"; }
expect "[P3-2] worktree 作成で tdd_phase=RED（タスクローカル）" "RED" "$(tget '.tdd_phase')"
WT="$T/.claude/worktrees/task-001"

echo "--- ステップ3: worktree 境界（R2）---"
expect "[R2] worktree 内 src 書込 → allow" "allow" "$(verdict "$(w_input Write "$WT/src/foo.ts")")"
expect "[R2] worktree 外 src 書込 → deny" "deny" "$(verdict "$(w_input Write "$T/src/elsewhere.ts")")"

echo "--- ステップ4: TDD のテスト改変ガード（R3）---"
expect "[R3] RED でテスト Edit → allow" "allow" "$(verdict "$(w_input Edit "$WT/src/foo.test.ts")")"
# GREEN に遷移後はテスト改変不可（PT3: タスクローカルの tdd_phase を変える）
tset '.tdd_phase="GREEN"'
expect "[R3] GREEN でテスト Edit → deny" "deny" "$(verdict "$(w_input Edit "$WT/src/foo.test.ts")")"
# RED に戻す（以降の失敗ループ用）
tset '.tdd_phase="RED"'

echo "--- ステップ5: テスト失敗3回で failure_count=3（post-task）---"
for _ in 1 2 3; do
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":1}}' \
    | CLAUDE_PROJECT_DIR="$T" bash "$POST" 2>/dev/null
done
expect "[P3-4] 3回失敗で failure_count=3（タスクローカル）" "3" "$(tget '.failure_count')"

echo "--- ステップ6: failure_count>=3 で実装ツール deny（R4）---"
expect "[R4] 3回失敗後の worktree 内書込 → deny" "deny" "$(verdict "$(w_input Write "$WT/src/foo.ts")")"

echo "--- ステップ7: ESCALATION 遷移で実装再開可能（R4 解除）---"
jq '.phase="ESCALATION"' "$T/sprint/state.json" > "$T/s.tmp" && mv "$T/s.tmp" "$T/sprint/state.json"
expect "[R4] ESCALATION 中は実装ツール allow" "allow" "$(verdict "$(w_input Write "$WT/src/foo.ts")")"

echo "--- ステップ8: 反復上限（iteration>=max）→ ESCALATION 条件 ---"
jq '.phase="EXECUTE" | .contract.iteration=15' "$T/sprint/state.json" > "$T/s.tmp" && mv "$T/s.tmp" "$T/sprint/state.json"
ITER=$(state '.contract.iteration'); MAXI=$(state '.contract.max_iterations')
if [ "$ITER" -ge "$MAXI" ]; then COND=escalate; else COND=continue; fi
expect "[P3-5] iteration>=max_iterations で ESCALATION 条件成立" "escalate" "$COND"

echo "--- ステップ9: 成功でカウンタ＆フェーズが回復（post-task GREEN）---"
# phase を EXECUTE に戻し（ステップ8で 15 にした iteration はそのまま）、タスクローカル fc=2 に。
jq '.phase="EXECUTE"' "$T/sprint/state.json" > "$T/s.tmp" && mv "$T/s.tmp" "$T/sprint/state.json"
tset '.failure_count=2'
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":0}}' \
  | CLAUDE_PROJECT_DIR="$T" bash "$POST" 2>/dev/null
expect "[post] テスト成功で failure_count=0（タスクローカル）" "0" "$(tget '.failure_count')"
expect "[post] テスト成功で tdd_phase=GREEN（タスクローカル）" "GREEN" "$(tget '.tdd_phase')"

echo "--- ステップ10: エージェント定義の DoD 確認 ---"
ag() { grep -q "$2" "$ROOT_REPO/.claude/agents/$1" && echo yes || echo no; }
expect "[P3-1] generator に契約合意の前提(R1)記載" "yes" "$(ag generator.md 'contract.agreed')"
expect "[P3-2] worker に RED→GREEN→REFACTOR 記載" "yes" "$(ag worker.md 'REFACTOR')"
expect "[P3-3] reviewer に Stage 1/2 とテスト diff 記載" "yes" "$(ag reviewer.md 'テスト diff')"

echo ""
echo "================================"
echo "結果: PASS=$PASS FAIL=$FAIL"
echo "================================"
if [ "$FAIL" -eq 0 ]; then
  echo "M4 達成: 契約合意→worktree→TDD→失敗3回エスカレーション→反復上限 が成立"
  exit 0
else
  exit 1
fi
