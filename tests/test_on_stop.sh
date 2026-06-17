#!/usr/bin/env bash
# tests/test_on_stop.sh
# on-stop.sh の単体テスト（Ring 2 温存・新トリガ）。
# 中断・再開機構（SUSPENDED / reset_at）は撤去済み。本フックは「未完スプリントの再開／
# クラウド再 clone 再開」を支える永続化層のトリガ役で、run_state を遷移させない。
# 永続化トリガ: SPRINT_FORCE_SHUTDOWN=1 または進行中フェーズ（DESIGN〜INTEGRATE）。

set -euo pipefail

PASS=0
FAIL=0

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

SPRINT_DIR="$TMPDIR_TEST/sprint"
HOOKS_DIR="$TMPDIR_TEST/.claude/sprint/hooks"
mkdir -p "$SPRINT_DIR" "$HOOKS_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_guard.sh" "$HOOKS_DIR/_guard.sh"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_state.sh" "$HOOKS_DIR/_state.sh"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_push.sh" "$HOOKS_DIR/_push.sh"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_control_commit.sh" "$HOOKS_DIR/_control_commit.sh"
cp "$SCRIPT_DIR/.claude/sprint/hooks/on-stop.sh" "$HOOKS_DIR/on-stop.sh"

# make_state [phase]（既定 EXECUTE＝進行中フェーズ＝永続化トリガを満たす）。run_state は RUNNING。
make_state() {
  local phase="${1:-EXECUTE}"
  cat > "$SPRINT_DIR/state.json" << EOF
{
  "sprint_id": "sprint-test",
  "phase": "$phase",
  "run_state": "RUNNING",
  "contract": {"agreed": true, "agreed_at": null, "iteration": 0, "max_iterations": 15},
  "tasks": {},
  "resilience": {
    "consecutive_tool_failures": 0,
    "persist_failed": false,
    "persist_failed_branches": []
  },
  "resume_hint": {
    "current_task": "task-01",
    "read_first": ["sprint/checkpoint.md", "sprint/state.json"],
    "next_action": "task-01 の実装を継続する"
  },
  "escalations_active": [],
  "escalations_archived_ref": null
}
EOF
}

assert_field() {
  local label="$1" field="$2" expected="$3"
  local actual
  actual=$(jq -r "$field" "$SPRINT_DIR/state.json" 2>/dev/null || echo "ERROR")
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected='$expected' actual='$actual'"
    FAIL=$((FAIL + 1))
  fi
}

# テストケース1: 非アクティブ状態（OFF）では no-op
echo "--- テスト: 非アクティブ状態では no-op ---"
make_state
jq '.run_state = "OFF"' "$SPRINT_DIR/state.json" > "$SPRINT_DIR/state.json.tmp" \
  && mv "$SPRINT_DIR/state.json.tmp" "$SPRINT_DIR/state.json"
BEFORE=$(cat "$SPRINT_DIR/state.json")
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null || true
AFTER=$(cat "$SPRINT_DIR/state.json")
if [ "$BEFORE" = "$AFTER" ]; then
  echo "PASS: OFF状態では state.json が変化しない"
  PASS=$((PASS + 1))
else
  echo "FAIL: OFF状態で state.json が変化してしまった"
  FAIL=$((FAIL + 1))
fi

# テストケース2: 永続化しても run_state は遷移しない（中断・再開機構の撤去）
echo "--- テスト: run_state を遷移させない（SUSPENDED 廃止） ---"
make_state
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
assert_field "永続化後も run_state は RUNNING のまま" ".run_state" "RUNNING"

# テストケース3: usage / reset_at を一切記録しない（撤去済み）
echo "--- テスト: usage / reset_at を記録しない ---"
make_state
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
assert_field "usage を作らない" ".usage // \"absent\"" "absent"

# テストケース4: checkpoint.md が生成される
echo "--- テスト: checkpoint.md が生成される ---"
make_state
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
CHECKPOINT_FILE="$SPRINT_DIR/checkpoint.md"
if [ -f "$CHECKPOINT_FILE" ]; then
  echo "PASS: checkpoint.md が生成された"
  PASS=$((PASS + 1))
else
  echo "FAIL: checkpoint.md が生成されなかった"
  FAIL=$((FAIL + 1))
fi

# テストケース5: checkpoint.md に必要な情報が含まれる
echo "--- テスト: checkpoint.md の内容確認 ---"
make_state
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
CHECKPOINT_FILE="$SPRINT_DIR/checkpoint.md"
if grep -q "task-01" "$CHECKPOINT_FILE" 2>/dev/null; then
  echo "PASS: checkpoint.md に実行中タスクが記載される"
  PASS=$((PASS + 1))
else
  echo "FAIL: checkpoint.md に実行中タスクが含まれない"
  FAIL=$((FAIL + 1))
fi
if grep -q "task-01 の実装を継続する" "$CHECKPOINT_FILE" 2>/dev/null; then
  echo "PASS: checkpoint.md に次のアクションが記載される"
  PASS=$((PASS + 1))
else
  echo "FAIL: checkpoint.md に次のアクションが含まれない"
  FAIL=$((FAIL + 1))
fi

# テストケース6: checkpoint.md が上書きされる（追記でない）
echo "--- テスト: checkpoint.md は上書き（追記でない） ---"
make_state
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
SIZE1=$(wc -c < "$SPRINT_DIR/checkpoint.md")
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
SIZE2=$(wc -c < "$SPRINT_DIR/checkpoint.md")
# サイズが2倍以上なら追記されている（失敗）
MAX_SIZE=$((SIZE1 * 15 / 10))  # 1.5倍を閾値
if [ "$SIZE2" -le "$MAX_SIZE" ]; then
  echo "PASS: 2回実行で checkpoint.md のサイズが適切（上書き）: $SIZE1 → $SIZE2 bytes"
  PASS=$((PASS + 1))
else
  echo "FAIL: 2回実行で checkpoint.md が大幅増加（追記の疑い）: $SIZE1 → $SIZE2 bytes"
  FAIL=$((FAIL + 1))
fi

# テストケース7: dirty な worktree がある場合 WIP コミットされる
echo "--- テスト: dirty worktree の WIP コミット ---"
make_state
WORKTREES_DIR="$TMPDIR_TEST/.claude/worktrees"
mkdir -p "$WORKTREES_DIR/task-01"
# 模擬 git リポジトリを作成（commit.gpgsign=false でサイン強制を回避）
git -C "$WORKTREES_DIR/task-01" init -q 2>/dev/null || true
git -C "$WORKTREES_DIR/task-01" config user.email "test@test.com" 2>/dev/null || true
git -C "$WORKTREES_DIR/task-01" config user.name "Test" 2>/dev/null || true
git -C "$WORKTREES_DIR/task-01" config commit.gpgsign false 2>/dev/null || true
echo "initial" > "$WORKTREES_DIR/task-01/file.txt"
git -C "$WORKTREES_DIR/task-01" add -A 2>/dev/null || true
git -C "$WORKTREES_DIR/task-01" commit -m "initial" -q 2>/dev/null || true
# dirty な変更を追加
echo "dirty change" >> "$WORKTREES_DIR/task-01/file.txt"

# git log が空リポジトリで exit 128 を返すため || true でエラーを吸収
BEFORE_LOG=0
BEFORE_LOG=$(git -C "$WORKTREES_DIR/task-01" log --oneline 2>/dev/null | wc -l) || true
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
AFTER_LOG=0
AFTER_LOG=$(git -C "$WORKTREES_DIR/task-01" log --oneline 2>/dev/null | wc -l) || true

if [ "$AFTER_LOG" -gt "$BEFORE_LOG" ]; then
  echo "PASS: dirty worktree が WIP コミットされた"
  PASS=$((PASS + 1))
else
  echo "FAIL: dirty worktree がコミットされなかった (before=$BEFORE_LOG, after=$AFTER_LOG)"
  FAIL=$((FAIL + 1))
fi

# テストケース8: 保全不要なフェーズ（CLARIFY）では永続化しない（トリガ条件）
echo "--- テスト: CLARIFY では永続化しない（トリガ条件） ---"
make_state "CLARIFY"
rm -rf "$WORKTREES_DIR"
rm -f "$SPRINT_DIR/checkpoint.md"
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
if [ ! -f "$SPRINT_DIR/checkpoint.md" ]; then
  echo "PASS: CLARIFY では永続化せず checkpoint.md を作らない"
  PASS=$((PASS + 1))
else
  echo "FAIL: CLARIFY なのに永続化した（checkpoint.md が作られた）"
  FAIL=$((FAIL + 1))
fi
assert_field "CLARIFY 永続化なしでも run_state は RUNNING のまま" ".run_state" "RUNNING"

# テストケース9: SPRINT_FORCE_SHUTDOWN=1 なら CLARIFY でも永続化する（明示トリガ）
echo "--- テスト: SPRINT_FORCE_SHUTDOWN=1 で明示永続化 ---"
make_state "CLARIFY"
rm -rf "$WORKTREES_DIR"
rm -f "$SPRINT_DIR/checkpoint.md"
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_FORCE_SHUTDOWN=1 \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
if [ -f "$SPRINT_DIR/checkpoint.md" ]; then
  echo "PASS: SPRINT_FORCE_SHUTDOWN=1 なら CLARIFY でも永続化する"
  PASS=$((PASS + 1))
else
  echo "FAIL: SPRINT_FORCE_SHUTDOWN=1 でも永続化しない"
  FAIL=$((FAIL + 1))
fi

# テストケース10: push 全失敗で persist_failed が記録される（IH-W5 / .resilience）
echo "--- テスト: push 全失敗で persist_failed 記録（IH-W5） ---"
make_state
WORKTREES_DIR="$TMPDIR_TEST/.claude/worktrees"
rm -rf "$WORKTREES_DIR"
mkdir -p "$WORKTREES_DIR/task-02"
git -C "$WORKTREES_DIR/task-02" init -q 2>/dev/null || true
git -C "$WORKTREES_DIR/task-02" checkout -q -b wbranch 2>/dev/null || true
git -C "$WORKTREES_DIR/task-02" config user.email "test@test.com" 2>/dev/null || true
git -C "$WORKTREES_DIR/task-02" config user.name "Test" 2>/dev/null || true
git -C "$WORKTREES_DIR/task-02" config commit.gpgsign false 2>/dev/null || true
echo "initial" > "$WORKTREES_DIR/task-02/file.txt"
git -C "$WORKTREES_DIR/task-02" add -A 2>/dev/null || true
git -C "$WORKTREES_DIR/task-02" commit -q -m "initial" 2>/dev/null || true
# 壊れた origin（push が必ず失敗する）
git -C "$WORKTREES_DIR/task-02" remote add origin "$TMPDIR_TEST/nonexistent.git" 2>/dev/null || true
# dirty 変更（WIP コミット対象）
echo "dirty" >> "$WORKTREES_DIR/task-02/file.txt"

OUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  SPRINT_PUSH_BACKOFF_BASE=0 \
  bash "$HOOKS_DIR/on-stop.sh" 2>&1)
assert_field "push 全失敗で persist_failed=true" ".resilience.persist_failed" "true"
if jq -e '.resilience.persist_failed_branches | index("wbranch")' "$SPRINT_DIR/state.json" >/dev/null 2>&1; then
  echo "PASS: persist_failed_branches に失敗ブランチが記録される"
  PASS=$((PASS + 1))
else
  echo "FAIL: persist_failed_branches に失敗ブランチが無い（$(jq -c '.resilience.persist_failed_branches' "$SPRINT_DIR/state.json" 2>/dev/null)）"
  FAIL=$((FAIL + 1))
fi
if echo "$OUT" | grep -q "警告"; then
  echo "PASS: push 失敗時に目立つ警告が出る"
  PASS=$((PASS + 1))
else
  echo "FAIL: push 失敗時の警告が出ない"
  FAIL=$((FAIL + 1))
fi

# テストケース11: push 成功なら persist_failed は立たない（冪等・偽陽性防止）
echo "--- テスト: push 成功時は persist_failed を立てない（IH-W5） ---"
make_state
rm -rf "$WORKTREES_DIR"
mkdir -p "$WORKTREES_DIR/task-03"
BARE_OK="$TMPDIR_TEST/bare-ok.git"
git init --bare -q "$BARE_OK" 2>/dev/null || true
git -C "$WORKTREES_DIR/task-03" init -q 2>/dev/null || true
git -C "$WORKTREES_DIR/task-03" checkout -q -b okbranch 2>/dev/null || true
git -C "$WORKTREES_DIR/task-03" config user.email "test@test.com" 2>/dev/null || true
git -C "$WORKTREES_DIR/task-03" config user.name "Test" 2>/dev/null || true
git -C "$WORKTREES_DIR/task-03" config commit.gpgsign false 2>/dev/null || true
echo "initial" > "$WORKTREES_DIR/task-03/file.txt"
git -C "$WORKTREES_DIR/task-03" add -A 2>/dev/null || true
git -C "$WORKTREES_DIR/task-03" commit -q -m "initial" 2>/dev/null || true
git -C "$WORKTREES_DIR/task-03" remote add origin "$BARE_OK" 2>/dev/null || true
echo "dirty" >> "$WORKTREES_DIR/task-03/file.txt"
CLAUDE_PROJECT_DIR="$TMPDIR_TEST" \
  SPRINT_PUSH_BACKOFF_BASE=0 \
  bash "$HOOKS_DIR/on-stop.sh" 2>/dev/null
assert_field "push 成功時は persist_failed が false のまま" ".resilience.persist_failed" "false"

# テストケース12: 制御面コミットが SPRINT_CONTROL_BRANCH に積まれる（IH-W6 / T1-1, T1-2）
echo "--- テスト: 制御面コミット（IH-W6） ---"
GR=$(mktemp -d)
mkdir -p "$GR/sprint" "$GR/.claude/sprint/hooks"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_guard.sh" "$GR/.claude/sprint/hooks/"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_state.sh" "$GR/.claude/sprint/hooks/"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_push.sh" "$GR/.claude/sprint/hooks/"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_control_commit.sh" "$GR/.claude/sprint/hooks/"
cp "$SCRIPT_DIR/.claude/sprint/hooks/on-stop.sh" "$GR/.claude/sprint/hooks/"
git -C "$GR" init -q 2>/dev/null || true
git -C "$GR" checkout -q -b main 2>/dev/null || true
git -C "$GR" config user.email "t@t.com" 2>/dev/null || true
git -C "$GR" config user.name "T" 2>/dev/null || true
git -C "$GR" config commit.gpgsign false 2>/dev/null || true
cat > "$GR/sprint/state.json" <<'EOF'
{ "sprint_id":"sprint-test","phase":"EXECUTE","run_state":"RUNNING",
  "resilience":{"consecutive_tool_failures":0,"persist_failed":false,"persist_failed_branches":[]},
  "resume_hint":{"current_task":"task-01","next_action":"継続"}, "escalations_active":[] }
EOF
echo "README" > "$GR/README"
git -C "$GR" add -A 2>/dev/null || true
git -C "$GR" commit -qm "init" 2>/dev/null || true
MAIN_HEAD_BEFORE=$(git -C "$GR" rev-parse HEAD 2>/dev/null || echo "")

CLAUDE_PROJECT_DIR="$GR" \
  SPRINT_CONTROL_BRANCH="sprint/test" SPRINT_PUSH_BACKOFF_BASE=0 \
  bash "$GR/.claude/sprint/hooks/on-stop.sh" >/dev/null 2>&1

if git -C "$GR" rev-parse --verify refs/heads/sprint/test >/dev/null 2>&1; then
  echo "PASS: SPRINT_CONTROL_BRANCH に制御面コミットが作られる"; PASS=$((PASS + 1))
else
  echo "FAIL: SPRINT_CONTROL_BRANCH が作られない"; FAIL=$((FAIL + 1))
fi
TREE_FILES=$(git -C "$GR" ls-tree -r --name-only refs/heads/sprint/test 2>/dev/null || echo "")
if echo "$TREE_FILES" | grep -q "sprint/state.json" && echo "$TREE_FILES" | grep -q "sprint/checkpoint.md"; then
  echo "PASS: 制御面コミットに state.json/checkpoint.md が含まれる"; PASS=$((PASS + 1))
else
  echo "FAIL: 制御面コミットに state.json/checkpoint.md が無い（$TREE_FILES）"; FAIL=$((FAIL + 1))
fi
# コミットメッセージ規約
CMSG=$(git -C "$GR" log -1 --format=%s refs/heads/sprint/test 2>/dev/null || echo "")
if echo "$CMSG" | grep -q "chore(sprint): checkpoint sprint-test"; then
  echo "PASS: コミットメッセージが規約どおり（$CMSG）"; PASS=$((PASS + 1))
else
  echo "FAIL: コミットメッセージが規約外（$CMSG）"; FAIL=$((FAIL + 1))
fi
# main 履歴に checkpoint が積まれない（現在ブランチ HEAD 不変）
MAIN_HEAD_AFTER=$(git -C "$GR" rev-parse HEAD 2>/dev/null || echo "")
if [ -n "$MAIN_HEAD_BEFORE" ] && [ "$MAIN_HEAD_BEFORE" = "$MAIN_HEAD_AFTER" ]; then
  echo "PASS: main 履歴に checkpoint が積まれない（HEAD 不変）"; PASS=$((PASS + 1))
else
  echo "FAIL: main HEAD が動いた（checkpoint 混入: $MAIN_HEAD_BEFORE → $MAIN_HEAD_AFTER）"; FAIL=$((FAIL + 1))
fi
# plumbing が本 index（.git/index）を汚さない（ステージが残らない）
if git -C "$GR" diff --cached --quiet 2>/dev/null; then
  echo "PASS: 本 index が汚れない（plumbing は一時 index を使用）"; PASS=$((PASS + 1))
else
  echo "FAIL: 本 index にステージが残った（$(git -C "$GR" diff --cached --name-only 2>/dev/null | head -3)）"; FAIL=$((FAIL + 1))
fi
# 冪等: 差分なし再実行で空コミットを作らない（コミット数不変）
COUNT1=$(git -C "$GR" rev-list --count refs/heads/sprint/test 2>/dev/null || echo 0)
CLAUDE_PROJECT_DIR="$GR" \
  SPRINT_CONTROL_BRANCH="sprint/test" SPRINT_PUSH_BACKOFF_BASE=0 \
  bash "$GR/.claude/sprint/hooks/on-stop.sh" >/dev/null 2>&1
COUNT2=$(git -C "$GR" rev-list --count refs/heads/sprint/test 2>/dev/null || echo 0)
if [ "$COUNT1" = "$COUNT2" ]; then
  echo "PASS: 差分なし再実行で空コミットを作らない（冪等・$COUNT1）"; PASS=$((PASS + 1))
else
  echo "FAIL: 冪等性が壊れた（$COUNT1 → $COUNT2）"; FAIL=$((FAIL + 1))
fi
rm -rf "$GR"

# 結果サマリー
echo ""
echo "================================"
echo "結果: PASS=$PASS, FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
