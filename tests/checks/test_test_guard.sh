#!/usr/bin/env bash
# tests/checks/test_test_guard.sh — R3 test_guard.sh の単体テスト
# PT1-3: 帰属を current_task からパス逆引き（テストファイル→worktree→task）へ。
# 並列で各タスクの tdd_phase により判定し、取り違えない。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT_REPO/.claude/sprint/policy/checks/test_guard.sh"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sprint" "$T/.claude/sprint/policy/checks" \
  "$T/.claude/worktrees/task-01/src/test" "$T/.claude/worktrees/task-01/latest" \
  "$T/.claude/worktrees/task-02/src"
cp "$ROOT_REPO/.claude/sprint/policy/checks/_task_from_path.sh" "$T/.claude/sprint/policy/checks/"
export ROOT="$T" STATE_FILE="$T/sprint/state.json"

# worktree 配下のパスを組み立てる
W1="$T/.claude/worktrees/task-01"
W2="$T/.claude/worktrees/task-02"

run() { FILE="$1" TOOL="${2:-Edit}" CWD="${3:-}" bash "$CHECK" >/dev/null 2>&1; echo $?; }
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected exit=$e got $a)"; FAIL=$((FAIL+1)); fi; }

# task-01 の tdd_phase を指定（worktree 付き）。
state_phase() {
  jq -nc --arg p "$1" \
    '{tasks:{"task-01":{status:"IN_PROGRESS",tdd_phase:$p,worktree:".claude/worktrees/task-01"}}}' > "$STATE_FILE"
}

echo "=== test_test_guard.sh (R3) ==="

# 正常: tdd_phase=RED でテスト Edit → allow
state_phase "RED"
expect "[正常] RED でテスト改変 → allow" 0 "$(run "$W1/foo.test.ts" Edit)"

# 違反: tdd_phase=GREEN でテスト Edit → deny
state_phase "GREEN"
expect "[違反] GREEN でテスト改変 → deny" 1 "$(run "$W1/foo.test.ts" Edit)"

# 対象外: テスト以外のファイル → allow
state_phase "GREEN"
expect "[対象外] 非テストファイル → allow" 0 "$(run "$W1/src/foo.ts" Edit)"

# 3-2: 部分文字列誤検知の回帰。"latest"/"contest"/"attestation" は test を含むが非テスト → allow
state_phase "GREEN"
expect "[3-2] commandlinetools_latest.zip → allow（誤検知しない）" 0 "$(run "$W1/commandlinetools_latest.zip" Edit)"
expect "[3-2] contest.js → allow（誤検知しない）" 0 "$(run "$W1/contest.js" Edit)"
expect "[3-2] attestation.json → allow（誤検知しない）" 0 "$(run "$W1/attestation.json" Edit)"
expect "[3-2] latest/config.yml（latest はセグメントだが test ではない）→ allow" 0 "$(run "$W1/latest/config.yml" Edit)"

# 3-2: トークン/セグメントとして test/spec を持つものは正しくテスト判定 → GREEN で deny
state_phase "GREEN"
expect "[3-2] FooTest.kt（JVM 命名）→ deny" 1 "$(run "$W1/FooTest.kt" Edit)"
expect "[3-2] test_foo.py（先頭トークン）→ deny" 1 "$(run "$W1/test_foo.py" Edit)"
expect "[3-2] src/test/Foo.kt（パスセグメント）→ deny" 1 "$(run "$W1/src/test/Foo.kt" Edit)"
expect "[3-2] foo.spec.ts → deny" 1 "$(run "$W1/foo.spec.ts" Edit)"

# 対象外: Edit 以外（Write） → allow
state_phase "GREEN"
expect "[対象外] Write は対象外 → allow" 0 "$(run "$W1/foo.test.ts" Write)"

# PT1-3: 並列で各タスクの tdd_phase により判定（取り違えない）
jq -nc '{tasks:{
  "task-01":{status:"IN_PROGRESS",tdd_phase:"RED",worktree:".claude/worktrees/task-01"},
  "task-02":{status:"IN_PROGRESS",tdd_phase:"GREEN",worktree:".claude/worktrees/task-02"}
}}' > "$STATE_FILE"
expect "[PT1-3] task-01(RED) のテスト改変 → allow" 0 "$(run "$W1/foo.test.ts" Edit)"
expect "[PT1-3] task-02(GREEN) のテスト改変 → deny" 1 "$(run "$W2/foo.test.ts" Edit)"

# 判定不能: worktree 外のテストファイル → タスク特定不能 → deny（fail-closed）
state_phase "RED"
expect "[判定不能] worktree 外のテスト改変 → deny" 1 "$(run "$T/foo.test.ts" Edit)"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
