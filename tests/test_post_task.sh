#!/usr/bin/env bash
# tests/test_post_task.sh — P1.5-4 post-task.sh の単体テスト
# テスト失敗で failure_count 加算、成功でリセット＋tdd_phase=GREEN を検証
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/sprint/hooks" "$T/.claude/sprint/policy/checks" "$T/sprint"
cp "$ROOT_REPO/.claude/sprint/hooks/_guard.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/hooks/_state.sh" "$T/.claude/sprint/hooks/"  # PT0-1: post-task が source する flock ヘルパ
cp "$ROOT_REPO/.claude/sprint/hooks/post-task.sh" "$T/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/policy/checks/_task_from_path.sh" "$T/.claude/sprint/policy/checks/"  # PT1-1: 帰属の逆引き
POST="$T/.claude/sprint/hooks/post-task.sh"

# 帰属は in_flight（単一）＝逐次運用相当。worktree も付ける（パス帰属の検証に使う）。
# PT3: タスクローカル状態は per-section でリセット（前セクションの failure_count を持ち越さない）。
make_state() {
  rm -f "$T/sprint/tasks/"*.status.json 2>/dev/null || true
  cat > "$T/sprint/state.json" <<'EOF'
{
  "run_state": "RUNNING",
  "resume_hint": {"in_flight": ["task-01"]},
  "tasks": {"task-01": {"status":"IN_PROGRESS","failure_count": 0, "tdd_phase": "RED", "worktree":".claude/worktrees/task-01"}}
}
EOF
}

field() { jq -r "$1" "$T/sprint/state.json"; }
# PT3: per-task の failure_count / tdd_phase はタスクローカル（sprint/tasks/<id>.status.json）が真実。
# 逆引きヘルパ task_field（タスクローカル優先・無ければ state.json）で読む。
export ROOT="$T" STATE_FILE="$T/sprint/state.json"
# shellcheck disable=SC1090
source "$ROOT_REPO/.claude/sprint/policy/checks/_task_from_path.sh"
tf() { task_field "$1" "$2" "${3:-}"; }
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

invoke() {
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$T" bash "$POST" 2>/dev/null
}

echo "=== test_post_task.sh ==="

# テスト失敗 → failure_count = 1
make_state
invoke '{"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":1}}'
expect "[失敗] pytest 失敗で failure_count=1" "1" "$(tf task-01 failure_count 0)"

# 連続失敗 → failure_count = 2
invoke '{"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":1}}'
expect "[失敗] 連続失敗で failure_count=2" "2" "$(tf task-01 failure_count 0)"

# テスト成功 → failure_count = 0, tdd_phase=GREEN
invoke '{"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":0}}'
expect "[成功] テスト成功で failure_count=0" "0" "$(tf task-01 failure_count 0)"
expect "[成功] テスト成功で tdd_phase=GREEN" "GREEN" "$(tf task-01 tdd_phase RED)"

# 非テストコマンド → 変化なし
make_state
invoke '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"exit_code":1}}'
expect "[対象外] 非テストコマンドは failure_count を変えない" "0" "$(tf task-01 failure_count 0)"

# 3回失敗到達 → failure_gate と連携できる状態か（failure_count=3）
make_state
for _ in 1 2 3; do
  invoke '{"tool_name":"Bash","tool_input":{"command":"jest"},"tool_response":{"exit_code":1}}'
done
expect "[連携] 3回失敗で failure_count=3（R4 連携）" "3" "$(tf task-01 failure_count 0)"

# --- PT1-5: パスベース帰属（並列で誤帰属しない） ---
make_parallel_state() {
  rm -f "$T/sprint/tasks/"*.status.json 2>/dev/null || true
  cat > "$T/sprint/state.json" <<'EOF'
{ "run_state":"RUNNING",
  "resume_hint":{"in_flight":["task-01","task-02"]},
  "tasks":{
    "task-01":{"status":"IN_PROGRESS","failure_count":0,"tdd_phase":"RED","worktree":".claude/worktrees/task-01"},
    "task-02":{"status":"IN_PROGRESS","failure_count":0,"tdd_phase":"RED","worktree":".claude/worktrees/task-02"}
  } }
EOF
}
# (a) コマンド内の worktree パスで task-02 に帰属
make_parallel_state
invoke '{"tool_name":"Bash","tool_input":{"command":"cd .claude/worktrees/task-02 && pytest"},"tool_response":{"exit_code":1}}'
expect "[PT1-5] コマンド内 worktree パスで task-02 に帰属" "1" "$(tf task-02 failure_count 0)"
expect "[PT1-5] 無関係な task-01 は不変" "0" "$(tf task-01 failure_count 0)"

# (b) cwd で task-01 に帰属（最優先源）
make_parallel_state
invoke '{"tool_name":"Bash","tool_input":{"command":"pytest"},"cwd":".claude/worktrees/task-01","tool_response":{"exit_code":1}}'
expect "[PT1-5] cwd で task-01 に帰属" "1" "$(tf task-01 failure_count 0)"
expect "[PT1-5] 無関係な task-02 は不変" "0" "$(tf task-02 failure_count 0)"

# (c) 帰属不能（2 in_flight・cwd/path 無し）→ 誤帰属しない（どちらも不変）
make_parallel_state
invoke '{"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":1}}'
expect "[PT1-5] 帰属不能なら task-01 不変（誤帰属しない）" "0" "$(tf task-01 failure_count 0)"
expect "[PT1-5] 帰属不能なら task-02 不変（誤帰属しない）" "0" "$(tf task-02 failure_count 0)"

# FR-4 二次（ベストエフォート）: ツール連続失敗カウンタ（外部監視の補助材料・.resilience 名前空間）
make_state
invoke '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"exit_code":1}}'
expect "[FR-4二次] ツール失敗で consecutive_tool_failures=1" "1" "$(field '.resilience.consecutive_tool_failures')"
invoke '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"exit_code":1}}'
expect "[FR-4二次] 連続失敗で consecutive_tool_failures=2" "2" "$(field '.resilience.consecutive_tool_failures')"
invoke '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"exit_code":0}}'
expect "[FR-4二次] 成功で consecutive_tool_failures=0 にリセット" "0" "$(field '.resilience.consecutive_tool_failures')"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
