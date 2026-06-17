#!/usr/bin/env bash
# tests/test_push_retry.sh
# IH-W5: 共通 push リトライヘルパ sprint_push_with_retry の単体テスト
#
# 検証:
#   - remote 未設定 → return 2（push 省略）・試行0回
#   - 正常 origin → return 0・試行1回
#   - 壊れた origin → return 1・既定4回試行（指数バックオフ）
#   - SPRINT_PUSH_MAX_RETRIES で回数を上書きできる（テスト容易性）
#
# set -e は付けない（戻り値を明示的に捕捉して検証するため。set -e 下では
# 関数の return 1 でスクリプトが終了してしまう）。

set -uo pipefail

PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/.claude/sprint/hooks/_push.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# 作業リポジトリを作る補助（1コミット済み）
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@test.com
  git -C "$dir" config user.name Test
  git -C "$dir" config commit.gpgsign false
  echo x > "$dir/f.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
}

export SPRINT_PUSH_BACKOFF_BASE=0   # テスト高速化（sleep 0）

# --- ケースA: remote 未設定 → return 2・試行0回 ---
echo "--- ケースA: remote 未設定 ---"
REPO_A="$TMPDIR_TEST/a"
make_repo "$REPO_A"
BR_A="$(git -C "$REPO_A" rev-parse --abbrev-ref HEAD)"
rc=0
sprint_push_with_retry "$REPO_A" "$BR_A" || rc=$?
[ "$rc" -eq 2 ] && pass "remote 未設定で return 2" || fail "remote 未設定 return 2 (rc=$rc)"
[ "${SPRINT_PUSH_ATTEMPTS}" -eq 0 ] && pass "remote 未設定で試行0回" || fail "試行0回 (ATTEMPTS=${SPRINT_PUSH_ATTEMPTS})"

# --- ケースB: 正常 origin → return 0・試行1回 ---
echo "--- ケースB: 正常 origin ---"
BARE_B="$TMPDIR_TEST/b.git"
git init --bare -q "$BARE_B"
REPO_B="$TMPDIR_TEST/b"
make_repo "$REPO_B"
git -C "$REPO_B" remote add origin "$BARE_B"
BR_B="$(git -C "$REPO_B" rev-parse --abbrev-ref HEAD)"
rc=0
sprint_push_with_retry "$REPO_B" "$BR_B" || rc=$?
[ "$rc" -eq 0 ] && pass "正常 origin で return 0" || fail "正常 origin return 0 (rc=$rc)"
[ "${SPRINT_PUSH_ATTEMPTS}" -eq 1 ] && pass "成功は1回試行" || fail "成功1回試行 (ATTEMPTS=${SPRINT_PUSH_ATTEMPTS})"

# --- ケースC: 壊れた origin → return 1・既定4回試行 ---
echo "--- ケースC: 壊れた origin（全失敗） ---"
REPO_C="$TMPDIR_TEST/c"
make_repo "$REPO_C"
git -C "$REPO_C" remote add origin "$TMPDIR_TEST/nonexistent.git"
BR_C="$(git -C "$REPO_C" rev-parse --abbrev-ref HEAD)"
rc=0
sprint_push_with_retry "$REPO_C" "$BR_C" || rc=$?
[ "$rc" -eq 1 ] && pass "全失敗で return 1" || fail "全失敗 return 1 (rc=$rc)"
[ "${SPRINT_PUSH_ATTEMPTS}" -eq 4 ] && pass "全失敗は4回試行（既定）" || fail "4回試行 (ATTEMPTS=${SPRINT_PUSH_ATTEMPTS})"

# --- ケースD: SPRINT_PUSH_MAX_RETRIES で回数上書き ---
echo "--- ケースD: MAX_RETRIES 上書き ---"
export SPRINT_PUSH_MAX_RETRIES=2
rc=0
sprint_push_with_retry "$REPO_C" "$BR_C" || rc=$?
[ "${SPRINT_PUSH_ATTEMPTS}" -eq 2 ] && pass "MAX_RETRIES=2 で2回試行" || fail "MAX_RETRIES上書き (ATTEMPTS=${SPRINT_PUSH_ATTEMPTS})"
unset SPRINT_PUSH_MAX_RETRIES

echo ""
echo "================================"
echo "結果: PASS=$PASS, FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
