#!/usr/bin/env bash
# tests/e2e_enforcement.sh — P1.5-6（M2達成判定）強制レイヤー E2E（負のテスト群）
# R1〜R5 ＋ R0（自己改変）＋ fail-closed を、pre-task.sh ディスパッチャ経由で網羅検証する。
# 対応する結合テスト仕様（tests/integration-test-spec.md）:
#   IT-01(fail-closed), IT-02(R0〜R5 dispatch), IT-03(Bash 迂回検査), IT-12(R5 精密化)
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/sprint/hooks" "$T/.claude/sprint/policy/checks" "$T/sprint" \
         "$T/.claude/worktrees/task-01/src" "$T/outside"
cp "$ROOT_REPO/.claude/sprint/hooks/_guard.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/hooks/pre-task.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/policy/checks/"*.sh "$T/.claude/sprint/policy/checks/"
: > "$T/sprint/SPRINT.md"
PRE="$T/.claude/sprint/hooks/pre-task.sh"

WT="$T/.claude/worktrees/task-01"

# 全規則を満たす baseline。各テストで1点だけ崩して「その規則のみ違反」を作る。
baseline_state() {
  local phase="${1:-EXECUTE}"
  cat > "$T/sprint/state.json" <<EOF
{
  "phase": "$phase",
  "run_state": "RUNNING",
  "contract": {"agreed": true},
  "tasks": {"task-01": {"status":"IN_PROGRESS","worktree":".claude/worktrees/task-01","tdd_phase":"RED","failure_count":0}},
  "resume_hint": {"current_task": "task-01"}
}
EOF
  # 承認記録は state.json と分離（R5: 自己承認防止）。既定で承認済みにしておく。
  echo '{"CLARIFY_TO_DESIGN":{"approved_by":"human","approved_at":"2026-06-01T00:00:00Z"}}' \
    > "$T/sprint/gate_approvals.json"
}

set_field() { jq "$1" "$T/sprint/state.json" > "$T/s.tmp" && mv "$T/s.tmp" "$T/sprint/state.json"; }

# ディスパッチャを実行し deny/allow を返す
verdict() {
  local input="$1" out
  out=$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$T" bash "$PRE" 2>/dev/null)
  if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    echo "deny"
  elif [ -z "$out" ]; then
    echo "allow"
  else
    echo "other"
  fi
}

w_input() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
# file_path + content（Write/Edit の内容検査用）
wc_input() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s","content":%s}}' "$1" "$2" "$(printf '%s' "$3" | jq -Rs .)"; }
# Bash コマンド入力
b_input() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

echo "=== e2e_enforcement.sh （強制レイヤー負のテスト） ==="

echo "--- R1: 仕様先行 ---"
baseline_state; set_field '.contract.agreed=false'
expect "[違反] 契約未合意で src 書込 → deny" "deny" "$(verdict "$(w_input Write "$WT/src/foo.ts")")"
baseline_state
expect "[正常] 契約合意済みで worktree 内 src 書込 → allow" "allow" "$(verdict "$(w_input Write "$WT/src/foo.ts")")"

echo "--- R2: worktree 境界 ---"
baseline_state
expect "[違反] worktree 外への書込 → deny" "deny" "$(verdict "$(w_input Write "$T/outside/foo.txt")")"
baseline_state
expect "[正常] worktree 内への書込 → allow" "allow" "$(verdict "$(w_input Write "$WT/src/bar.ts")")"

echo "--- R3: テスト改変禁止 ---"
baseline_state; set_field '.tasks["task-01"].tdd_phase="GREEN"'
expect "[違反] GREEN でテスト Edit → deny" "deny" "$(verdict "$(w_input Edit "$WT/src/foo.test.ts")")"
baseline_state
expect "[正常] RED でテスト Edit → allow" "allow" "$(verdict "$(w_input Edit "$WT/src/foo.test.ts")")"

echo "--- R4: 3回失敗ゲート ---"
baseline_state; set_field '.tasks["task-01"].failure_count=3'
expect "[違反] failure_count=3 で書込 → deny" "deny" "$(verdict "$(w_input Write "$WT/src/foo.ts")")"
baseline_state; set_field '.tasks["task-01"].failure_count=2'
expect "[正常] failure_count=2 で書込 → allow" "allow" "$(verdict "$(w_input Write "$WT/src/foo.ts")")"

echo "--- R5: フェーズゲート承認 ---"
baseline_state CLARIFY; echo '{"CLARIFY_TO_DESIGN":null}' > "$T/sprint/gate_approvals.json"
expect "[違反] CLARIFY 承認なしで state.json 書込 → deny" "deny" "$(verdict "$(w_input Write "$T/sprint/state.json")")"
baseline_state CLARIFY
expect "[正常] CLARIFY 承認ありで state.json 書込 → allow" "allow" "$(verdict "$(w_input Write "$T/sprint/state.json")")"
baseline_state CLARIFY
expect "[違反] gate_approvals.json への自己承認書込 → deny" "deny" "$(verdict "$(w_input Write "$T/sprint/gate_approvals.json")")"

echo "--- R0: 自己改変防止 ---"
baseline_state
expect "[違反] hooks/_guard.sh を Write → deny" "deny" "$(verdict "$(w_input Write "$T/.claude/sprint/hooks/_guard.sh")")"
baseline_state
expect "[違反] policy/rules.json を Edit → deny" "deny" "$(verdict "$(w_input Edit "$T/.claude/sprint/policy/rules.json")")"
baseline_state
BASH_PWN='{"tool_name":"Bash","tool_input":{"command":"echo x >> .claude/sprint/hooks/pre-task.sh"}}'
expect "[違反] Bash でフック改変 → deny" "deny" "$(verdict "$BASH_PWN")"

echo "--- Bash 迂回検査（§7.6: echo > file / mv / jq > 等） ---"
# R2: Bash リダイレクトで worktree 外（プロジェクト内）へ書込 → deny
baseline_state
expect "[違反] Bash で worktree 外へリダイレクト → deny" "deny" \
  "$(verdict "$(b_input "echo x > $T/outside/foo.txt")")"
# R2: Bash リダイレクトで worktree 内へ書込 → allow
baseline_state
expect "[正常] Bash で worktree 内へリダイレクト → allow" "allow" \
  "$(verdict "$(b_input "echo x > $WT/src/foo.ts")")"
# R2: プロジェクト外（/tmp）への通常リダイレクトは対象外 → allow
baseline_state
expect "[正常] Bash でプロジェクト外(/tmp)へリダイレクト → allow" "allow" \
  "$(verdict "$(b_input "echo x > /tmp/sprint_test_$$")")"
# R5: Bash で state.json を CLARIFY 未承認のまま書換 → deny（内容不明=fail-closed）
baseline_state CLARIFY; echo '{"CLARIFY_TO_DESIGN":null}' > "$T/sprint/gate_approvals.json"
expect "[違反] Bash で CLARIFY 中の state.json 書換 → deny" "deny" \
  "$(verdict "$(b_input "jq '.phase=\"DESIGN\"' $T/sprint/state.json > /tmp/s && mv /tmp/s $T/sprint/state.json")")"
# R0: Bash の mv でフックを置換 → deny（mv 宛先抽出）
baseline_state
expect "[違反] Bash の mv でフック置換 → deny" "deny" \
  "$(verdict "$(b_input "mv /tmp/x $T/.claude/sprint/hooks/on-stop.sh")")"

echo "--- R5 精密化（phase を変えない CLARIFY 更新は許可） ---"
# 未承認でも phase を変えない state.json 更新（resume_hint 等）→ allow
baseline_state CLARIFY; echo '{"CLARIFY_TO_DESIGN":null}' > "$T/sprint/gate_approvals.json"
expect "[正常] CLARIFY 未承認・phase 据置の state.json 更新 → allow" "allow" \
  "$(verdict "$(wc_input Write "$T/sprint/state.json" '{"phase":"CLARIFY","resume_hint":{"next_action":"x"}}')")"
# 未承認で phase=DESIGN へ変更する内容 → deny
baseline_state CLARIFY; echo '{"CLARIFY_TO_DESIGN":null}' > "$T/sprint/gate_approvals.json"
expect "[違反] CLARIFY 未承認・phase=DESIGN へ変更 → deny" "deny" \
  "$(verdict "$(wc_input Write "$T/sprint/state.json" '{"phase":"DESIGN"}')")"

echo "--- Fail-closed: 判定不能 ---"
# RUNNING は読めるが必須フィールド（contract）欠落 → spec_loaded が agreed=false 扱いで deny
baseline_state; set_field 'del(.contract)'
expect "[判定不能] contract 欠落で src 書込 → deny" "deny" "$(verdict "$(w_input Write "$WT/src/foo.ts")")"

echo ""
echo "================================"
echo "結果: PASS=$PASS FAIL=$FAIL"
echo "================================"
if [ "$FAIL" -eq 0 ]; then
  echo "M2 達成: 全違反シナリオが PreToolUse でブロックされた"
  exit 0
else
  exit 1
fi
