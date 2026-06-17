#!/usr/bin/env bash
# tests/test_worktree_branch_naming.sh
# narou-reader feedback C / §3 P1: stale worktree-* 衝突根絶。
#   固定名 worktree-$TASK が（ローカル/origin に）既存のとき、再開・再試行で別歴史を push すると
#   非 fast-forward で reject される（--force-with-lease は auto mode 分類器で不可）。
#   worktree.sh create が未使用名（必要なら -rN）を選び、採用した実名を
#   state.json.tasks[<id>].branch に記録すること。finish はその実名ブランチを使うことを検証する。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/sprint"
cp "$ROOT_REPO/scripts/worktree.sh" "$T/scripts/"
mkdir -p "$T/.claude/sprint/hooks"
cp "$ROOT_REPO/.claude/sprint/hooks/_push.sh" "$ROOT_REPO/.claude/sprint/hooks/_state.sh" "$T/.claude/sprint/hooks/"

git -C "$T" init -q
git -C "$T" config user.email t@t.com; git -C "$T" config user.name T
git -C "$T" config commit.gpgsign false
echo base > "$T/README"
cat > "$T/sprint/state.json" <<'EOF'
{ "sprint_id":"sprint-1","phase":"EXECUTE","run_state":"RUNNING",
  "contract":{"agreed":true}, "tasks":{}, "escalations_active":[] }
EOF
git -C "$T" add -A; git -C "$T" commit -qm init
DEFBR=$(git -C "$T" symbolic-ref --short HEAD)

expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }
branch_of() { jq -r --arg t "$1" '.tasks[$t].branch // ""' "$T/sprint/state.json"; }

echo "=== test_worktree_branch_naming.sh (C / §3 P1) ==="

# 1) 衝突無し → 固定名 worktree-task-001（後方互換）
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" create task-001 >/dev/null 2>&1
expect "[C] 衝突なしは worktree-task-001" "worktree-task-001" "$(branch_of task-001)"

# 2) ローカルに worktree-task-010 が既存 → 別名 -r1 を選び state に記録
git -C "$T" branch worktree-task-010 "$DEFBR"
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" create task-010 >/dev/null 2>&1
expect "[C] ローカル衝突は worktree-task-010-r1" "worktree-task-010-r1" "$(branch_of task-010)"
expect "[C] 別名でも worktree ディレクトリが作られる" "yes" \
  "$([ -d "$T/.claude/worktrees/task-010" ] && echo yes || echo no)"

# 3) ローカルに無いが origin に worktree-task-020 が既存（stale）→ 別名 -r1 を選ぶ
git init --bare -q "$T/origin.git"
git -C "$T" remote add origin "$T/origin.git"
git -C "$T" push -q origin "$DEFBR"
git -C "$T" branch worktree-task-020 "$DEFBR"
git -C "$T" push -q origin worktree-task-020
git -C "$T" branch -D worktree-task-020 >/dev/null 2>&1   # ローカルから消す（origin にのみ＝stale）
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" create task-020 >/dev/null 2>&1
expect "[C] origin stale 衝突も worktree-task-020-r1" "worktree-task-020-r1" "$(branch_of task-020)"

# 4) finish は state 記録の実名ブランチを使う（別名でも finish できる）
echo content > "$T/.claude/worktrees/task-010/feature.txt"
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" finish task-010 "feat: task-010" >/dev/null 2>&1
expect "[C] 別名タスクも finish で COMPLETE" "COMPLETE" "$(jq -r '.tasks["task-010"].status' "$T/sprint/state.json")"
expect "[C] finish が実名ブランチ worktree-task-010-r1 にコミット" "yes" \
  "$(git -C "$T" rev-parse --verify worktree-task-010-r1 >/dev/null 2>&1 && git -C "$T" cat-file -e worktree-task-010-r1:feature.txt 2>/dev/null && echo yes || echo no)"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
