#!/usr/bin/env bash
# tests/test_task_local_gitignore.sh — sprint-9 教訓: タスクローカル状態（sprint/tasks/*.status.json）が
# git 追跡されない（gitignored）ことを実 .gitignore で検証する。
#
# 追跡すると harness の Stop フック git-check が「未コミット変更」として警告し、Orchestrator が
# root へ保全コミット → worktree も同名ファイルを持ち、INTEGRATE のマージで add/add 競合で停止する。
# 本テストは「status.json は ignore される／.gitkeep・task-template.md は追跡できる」を固定する。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITIGNORE_SRC="$ROOT_REPO/.gitignore"
PASS=0; FAIL=0
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

echo "=== test_task_local_gitignore.sh (sprint-9) ==="

if ! command -v git >/dev/null 2>&1; then
  echo "  SKIP: git 不在のため検証をスキップ"
  echo "結果: PASS=$PASS FAIL=$FAIL"
  exit 0
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
git -C "$T" config user.email t@example.com
git -C "$T" config user.name test
# 実リポジトリの .gitignore をそのまま使う（ルールのドリフトを検出するため）。
cp "$GITIGNORE_SRC" "$T/.gitignore"
mkdir -p "$T/sprint/tasks"
: > "$T/sprint/tasks/.gitkeep"
: > "$T/sprint/tasks/task-template.md"
printf '{"failure_count":1}\n' > "$T/sprint/tasks/task-001.status.json"
: > "$T/sprint/tasks/task-001.lock"

# 1) status.json は ignore される
git -C "$T" check-ignore -q sprint/tasks/task-001.status.json
expect "[gitignore] sprint/tasks/*.status.json は ignore される" "0" "$?"

# 2) lock 実体も ignore される（既存規則の回帰）
git -C "$T" check-ignore -q sprint/tasks/task-001.lock
expect "[gitignore] sprint/tasks/*.lock は ignore される" "0" "$?"

# 3) .gitkeep と task-template.md は ignore されない（追跡可能を維持）
git -C "$T" check-ignore -q sprint/tasks/.gitkeep; rc=$?
expect "[gitignore] .gitkeep は追跡可能（ignore されない）" "1" "$rc"
git -C "$T" check-ignore -q sprint/tasks/task-template.md; rc=$?
expect "[gitignore] task-template.md は追跡可能（ignore されない）" "1" "$rc"

# 4) git add -A しても status.json/lock はステージされない（add/add 競合の温床を断つ）
git -C "$T" add -A
STAGED=$(git -C "$T" diff --cached --name-only | tr '\n' ' ')
case "$STAGED" in
  *status.json*) expect "[add -A] status.json はステージされない" "no" "yes" ;;
  *)             expect "[add -A] status.json はステージされない" "no" "no" ;;
esac
case "$STAGED" in
  *.lock*) expect "[add -A] lock はステージされない" "no" "yes" ;;
  *)       expect "[add -A] lock はステージされない" "no" "no" ;;
esac
case "$STAGED" in
  *task-template.md*) expect "[add -A] task-template.md はステージされる" "yes" "yes" ;;
  *)                  expect "[add -A] task-template.md はステージされる" "yes" "no" ;;
esac

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
