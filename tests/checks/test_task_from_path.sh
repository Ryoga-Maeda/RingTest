#!/usr/bin/env bash
# tests/checks/test_task_from_path.sh — PT1-1: パス→タスク逆引きヘルパ _task_from_path.sh の単体テスト
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT_REPO/.claude/sprint/policy/checks/_task_from_path.sh"
PASS=0; FAIL=0
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected='$e' got='$a')"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/worktrees/task-01/src" "$T/.claude/worktrees/task-02/tests" "$T/sprint" "$T/outside"
export ROOT="$T" STATE_FILE="$T/sprint/state.json"
cat > "$STATE_FILE" <<'EOF'
{"tasks":{
  "task-01":{"status":"IN_PROGRESS","tdd_phase":"RED","failure_count":1,"worktree":".claude/worktrees/task-01"},
  "task-02":{"status":"COMPLETE","worktree":".claude/worktrees/task-02"}
}}
EOF
# shellcheck disable=SC1090
source "$HELPER"

echo "=== test_task_from_path.sh (PT1-1) ==="

# 絶対パス → task 抽出
expect "[抽出] worktree 配下の絶対パス → task-01" "task-01" "$(task_from_path "$T/.claude/worktrees/task-01/src/a.ts"; true)"
expect "[抽出] 別 worktree → task-02" "task-02" "$(task_from_path "$T/.claude/worktrees/task-02/tests/b.ts"; true)"

# 相対パス（ROOT 基準）→ task 抽出
expect "[抽出] 相対パスも ROOT 基準で解決" "task-01" "$(task_from_path ".claude/worktrees/task-01/src/a.ts"; true)"

# 末尾スラッシュ・.. を含むパス
expect "[正規化] worktree ルート自体" "task-01" "$(task_from_path "$T/.claude/worktrees/task-01"; true)"
expect "[正規化] .. を含むパス" "task-02" "$(task_from_path "$T/.claude/worktrees/task-01/../task-02/x"; true)"

# CRLF 混入
expect "[CRLF] 末尾 CR を除去" "task-01" "$(task_from_path "$(printf '%s\r' "$T/.claude/worktrees/task-01/src/a.ts")"; true)"

# worktree 外 → 空＋非ゼロ
expect "[外] worktree 外パス → 空" "" "$(task_from_path "$T/outside/c.ts"; true)"
task_from_path "$T/outside/c.ts" >/dev/null 2>&1; expect "[外] 非ゼロ終了" "1" "$?"
expect "[外] 空文字列 → 空" "" "$(task_from_path ""; true)"

# task_from_file_or_cwd: FILE 優先・CWD フォールバック
expect "[file_or_cwd] FILE で引ける" "task-01" "$(task_from_file_or_cwd "$T/.claude/worktrees/task-01/src/a.ts" "$T/.claude/worktrees/task-02"; true)"
expect "[file_or_cwd] FILE 不可なら CWD" "task-02" "$(task_from_file_or_cwd "$T/outside/c.ts" "$T/.claude/worktrees/task-02"; true)"
expect "[file_or_cwd] 両方不可 → 空" "" "$(task_from_file_or_cwd "$T/outside/c.ts" "$T/outside"; true)"

# task_status / task_field（タスクローカル無し → state.json へ縮退＝後方互換/マイグレーション）
expect "[status] task-01 は IN_PROGRESS（state.json 縮退）" "IN_PROGRESS" "$(task_status task-01)"
expect "[status] task-02 は COMPLETE" "COMPLETE" "$(task_status task-02)"
expect "[field] task-01 の failure_count（state.json 縮退）" "1" "$(task_field task-01 failure_count 0)"
expect "[field] 未定義キーは既定値" "0" "$(task_field task-99 failure_count 0)"

# PT3: タスクローカル（sprint/tasks/<id>.status.json）があれば優先する
mkdir -p "$T/sprint/tasks"
echo '{"failure_count":2,"tdd_phase":"GREEN"}' > "$T/sprint/tasks/task-01.status.json"
expect "[PT3] failure_count はタスクローカル優先（2）" "2" "$(task_field task-01 failure_count 0)"
expect "[PT3] tdd_phase はタスクローカル優先（GREEN）" "GREEN" "$(task_field task-01 tdd_phase RED)"
# タスクローカルに無いフィールド（status）は state.json へ縮退
expect "[PT3] タスクローカルに無い status は state.json（IN_PROGRESS）" "IN_PROGRESS" "$(task_status task-01)"
# タスクローカルに null のフィールドは state.json へ縮退
echo '{"failure_count":5,"tdd_phase":null}' > "$T/sprint/tasks/task-01.status.json"
expect "[PT3] タスクローカル null は state.json へ縮退（tdd_phase=RED）" "RED" "$(task_field task-01 tdd_phase RED)"
expect "[PT3] failure_count=5 はタスクローカル" "5" "$(task_field task-01 failure_count 0)"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
