#!/usr/bin/env bash
# tests/test_worktree_env_propagation.sh
# sprint-2 報告／retro 4-3: worktree.sh create が root の gitignore 対象環境ファイル
# （local.properties 等）を新規 worktree へ伝播することを検証する。
# git worktree add は未追跡/無視ファイルをコピーしないため、明示コピーが必要。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/sprint"
cp "$ROOT_REPO/scripts/worktree.sh" "$T/scripts/"
# IH-W5/PT0-1: worktree.sh が source する共通 push/state ヘルパを配置
mkdir -p "$T/.claude/sprint/hooks"; cp "$ROOT_REPO/.claude/sprint/hooks/_push.sh" "$ROOT_REPO/.claude/sprint/hooks/_state.sh" "$T/.claude/sprint/hooks/"

git -C "$T" init -q
git -C "$T" config user.email t@t.com; git -C "$T" config user.name T
git -C "$T" config commit.gpgsign false
echo base > "$T/README"
cat > "$T/sprint/state.json" <<'EOF'
{ "sprint_id":"sprint-1","phase":"EXECUTE","run_state":"RUNNING",
  "contract":{"agreed":true}, "tasks":{}, "escalations_active":[] }
EOF
# .gitignore で local.properties を無視（= git worktree add はコピーしない）。
printf 'local.properties\n.env\n' > "$T/.gitignore"
git -C "$T" add -A; git -C "$T" commit -qm init

# root に gitignore 対象の環境ファイルを置く（git 追跡されない）。
echo "sdk.dir=/home/user/android-sdk" > "$T/local.properties"
echo "TOKEN=secret" > "$T/.env"

expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

echo "=== test_worktree_env_propagation.sh (4-3) ==="

# 1) 既定: local.properties / .env が worktree へ伝播する
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" create task-001 >/dev/null
WT="$T/.claude/worktrees/task-001"
expect "[4-3] local.properties が worktree へ伝播" "yes" "$([ -f "$WT/local.properties" ] && echo yes || echo no)"
expect "[4-3] .env が worktree へ伝播" "yes" "$([ -f "$WT/.env" ] && echo yes || echo no)"
expect "[4-3] 伝播した local.properties の内容が一致" "sdk.dir=/home/user/android-sdk" "$(cat "$WT/local.properties")"

# 2) root に環境ファイルが無ければ何もしない（エラーにしない）
rm -f "$T/local.properties" "$T/.env"
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" create task-002 >/dev/null; RC=$?
expect "[4-3] 環境ファイル不在でも create は成功" 0 "$RC"
expect "[4-3] 環境ファイル不在なら worktree にも作られない" "no" \
  "$([ -f "$T/.claude/worktrees/task-002/local.properties" ] && echo yes || echo no)"

# 3) SPRINT_WORKTREE_ENV_FILES で対象を上書きできる
echo "CUSTOM=1" > "$T/myenv.conf"
printf 'myenv.conf\n' >> "$T/.gitignore"
SPRINT_WORKTREE_ENV_FILES="myenv.conf" CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/worktree.sh" create task-003 >/dev/null
expect "[4-3] SPRINT_WORKTREE_ENV_FILES の対象が伝播" "yes" \
  "$([ -f "$T/.claude/worktrees/task-003/myenv.conf" ] && echo yes || echo no)"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
