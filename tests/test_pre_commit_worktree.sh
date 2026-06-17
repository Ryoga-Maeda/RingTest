#!/usr/bin/env bash
# tests/test_pre_commit_worktree.sh
# 回帰テスト（sprint-2 報告 3-A/4-1, §6 最小再現）:
#   リンクド worktree（<main>/.claude/worktrees/<task>）からの worktree 内コミットが
#   pre-commit で誤拒否されないこと（WORKTREE_TOP 確定・FILE/ROOT 分離）。
#   併せて、進行中タスクの worktree 外（root 直下）への書込は引き続き拒否されること。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# フレームワークのフック／チェック／worktree.sh を temp リポジトリへ配置する。
mkdir -p "$T/.githooks" "$T/.claude/sprint/policy/checks" "$T/scripts" "$T/sprint" "$T/app"
cp "$ROOT_REPO/.githooks/pre-commit" "$T/.githooks/"
cp "$ROOT_REPO/.claude/sprint/policy/checks/worktree_boundary.sh" \
   "$ROOT_REPO/.claude/sprint/policy/checks/self_protect.sh" \
   "$ROOT_REPO/.claude/sprint/policy/checks/_task_from_path.sh" "$T/.claude/sprint/policy/checks/"
cp "$ROOT_REPO/scripts/worktree.sh" "$T/scripts/"
# IH-W5/PT0-1: worktree.sh が source する共通 push/state ヘルパを配置
mkdir -p "$T/.claude/sprint/hooks"; cp "$ROOT_REPO/.claude/sprint/hooks/_push.sh" "$ROOT_REPO/.claude/sprint/hooks/_state.sh" "$T/.claude/sprint/hooks/"

git -C "$T" init -q
git -C "$T" config user.email t@t.com; git -C "$T" config user.name T
git -C "$T" config commit.gpgsign false

echo base > "$T/app/Base.kt"
cat > "$T/sprint/state.json" <<'EOF'
{ "sprint_id":"sprint-1","phase":"EXECUTE","run_state":"RUNNING",
  "contract":{"agreed":true}, "tasks":{}, "escalations_active":[] }
EOF
git -C "$T" add -A; git -C "$T" commit -qm init >/dev/null 2>&1

# pre-commit を絶対パスで有効化（4-2 と同じ設定）。初期コミット後に設定する
# （RUNNING 状態の初期コミット自体が境界チェックに掛からないようにするため）。
git -C "$T" config core.hooksPath "$T/.githooks"

echo "=== test_pre_commit_worktree.sh ==="

echo "--- ステップ1: worktree 作成（IN_PROGRESS） ---"
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" create task-001 >/dev/null
WT="$T/.claude/worktrees/task-001"
expect "[setup] worktree が作成される" "yes" "$([ -d "$WT" ] && echo yes || echo no)"

echo "--- ステップ2: worktree 内コミットが pre-commit を通る（3-A 修正の核心） ---"
echo "class EpisodeContent" > "$WT/app/EpisodeContent.kt"
git -C "$WT" add -A
if git -C "$WT" commit -m "feat: task-001 worktree 内コミット" >/tmp/wt_commit.log 2>&1; then
  COMMIT_RESULT="ok"
else
  COMMIT_RESULT="rejected"
fi
expect "[3-A/4-1] リンクド worktree 内のファイルコミットが pre-commit を通る" "ok" "$COMMIT_RESULT"
[ "$COMMIT_RESULT" = "rejected" ] && { echo "    --- pre-commit 出力 ---"; sed 's/^/    /' /tmp/wt_commit.log; }

echo "--- ステップ3: root 直下（worktree 外）への書込は引き続き拒否される ---"
echo "leak" > "$T/app/Leak.kt"
git -C "$T" add app/Leak.kt
if git -C "$T" commit -m "root 直下への混入" >/dev/null 2>&1; then
  ROOT_RESULT="ok"
else
  ROOT_RESULT="rejected"
fi
expect "[境界維持] 進行中タスクの worktree 外（root）への書込は pre-commit が拒否する" "rejected" "$ROOT_RESULT"
git -C "$T" reset -q HEAD app/Leak.kt 2>/dev/null || true

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
