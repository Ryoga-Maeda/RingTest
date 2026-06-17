#!/usr/bin/env bash
# tests/test_pre_commit_settings.sh
# FR-2 / M-1: 壊れた settings.json のコミットを pre-commit が拒否する（スプリント外でも効く）。
set -uo pipefail
ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.githooks" "$T/scripts" "$T/.claude" "$T/.claude/sprint/policy/checks"
cp "$ROOT_REPO/.githooks/pre-commit" "$T/.githooks/"
cp "$ROOT_REPO/scripts/validate-settings.sh" "$T/scripts/"
cp "$ROOT_REPO/.claude/sprint/policy/checks/worktree_boundary.sh" \
   "$ROOT_REPO/.claude/sprint/policy/checks/self_protect.sh" "$T/.claude/sprint/policy/checks/" 2>/dev/null || true

git -C "$T" init -q
git -C "$T" config user.email t@t.com; git -C "$T" config user.name T
git -C "$T" config commit.gpgsign false
git -C "$T" config core.hooksPath "$T/.githooks"
echo base > "$T/README"
git -C "$T" add -A; git -C "$T" commit -qm init >/dev/null 2>&1

echo "=== test_pre_commit_settings.sh（FR-2 / M-1）==="

# ケース1: 壊れた .claude/settings.json のコミットを拒否（スプリント外＝state.json 無し）
printf '{ broken json\n' > "$T/.claude/settings.json"
git -C "$T" add .claude/settings.json
EC=0; git -C "$T" commit -qm "bad settings" >/dev/null 2>&1 || EC=$?
expect "壊れた settings.json のコミットを拒否" "fail" "$([ "$EC" -ne 0 ] && echo fail || echo pass)"

# ケース2: 正常な .claude/settings.json は通過
printf '{ "language": "ja" }\n' > "$T/.claude/settings.json"
git -C "$T" add .claude/settings.json
EC=0; git -C "$T" commit -qm "good settings" >/dev/null 2>&1 || EC=$?
expect "正常な settings.json のコミットは通過" "0" "$EC"

# ケース3: 壊れた .claude/sprint/settings.json も拒否
mkdir -p "$T/.claude/sprint"
printf '{ "hooks": { "Stop": { "bad": true } } }\n' > "$T/.claude/sprint/settings.json"
git -C "$T" add .claude/sprint/settings.json
EC=0; git -C "$T" commit -qm "bad sprint settings" >/dev/null 2>&1 || EC=$?
expect "スキーマ不適合な sprint/settings.json を拒否" "fail" "$([ "$EC" -ne 0 ] && echo fail || echo pass)"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
