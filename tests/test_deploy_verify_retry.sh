#!/usr/bin/env bash
# tests/test_deploy_verify_retry.sh — deploy-sprint.sh 検証リトライ（課題B-2）の単体テスト
#
# 位置づけ: development/deploy-sprint-verify-hardening-plan.md「課題B」への対応。
#   9p（WSL2 /mnt/c）の一過性 ENOENT で自動検証が誤 FAIL する事象を緩和するため、
#   deploy-sprint.sh の検証は「最大2回試行（1回だけリトライ）」へ堅牢化された。
#   9p の一過性は Linux（ext4）で再現困難なため、リトライ制御部そのものを単体検証する。
#
# テスト方法の設計判断:
#   deploy-sprint.sh は検証時に TARGET の tests/test_isolation.sh を実行するが、deploy 自身が
#   merge_dir で tests/ をテンプレート版に上書きするため、TARGET 側のダミー test に差し替えるのは
#   難しい。そこで検証リトライのロジックを deploy-sprint.sh 内の関数 _verify_with_retry に切り出し、
#   本テストはスクリプトを source して当該関数を「N回目で成功するダミーコマンド」で直接駆動する。
#   これにより 9p に依存せず「1回目失敗→2回目成功で成功扱い／常に失敗で失敗扱い／最大2回しか
#   呼ばれない」という制御の核を決定論的に検証できる。
#
# set -e は付けない（_verify_with_retry の戻り値を明示的に捕捉して検証するため）。
set -uo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="$SCRIPT_DIR/scripts/deploy-sprint.sh"

echo "=== test_deploy_verify_retry.sh（検証リトライ B-2 単体テスト）==="

# ライブラリとして source（本処理は source 検知で return し、関数定義のみ取り込む）。
QUIET=1
# shellcheck disable=SC1090
source "$DEPLOY"

# 実体化を確認（関数が無ければ以降の検証は無意味）。
check "前提: _verify_with_retry が定義されている" "function" "$(type -t _verify_with_retry || true)"

# sleep を無効化してテストを高速化（リトライ間の sleep 1 を no-op に差し替え）。
# 実挙動（試行回数・成否）には影響しない。
sleep() { :; }

# 試行回数を記録しつつ、$ATTEMPTS_TO_FAIL 回までは失敗・以降は成功するダミー検証コマンド。
CALLS=0
ATTEMPTS_TO_FAIL=0
dummy_verify() {
  CALLS=$((CALLS + 1))
  if [ "$CALLS" -le "$ATTEMPTS_TO_FAIL" ]; then
    return 1
  fi
  return 0
}

# --- ケース1: 1回目失敗・2回目成功 → 成功扱い ---
echo ""
echo "ケース1: 1回目失敗・2回目成功 → 成功扱い（リトライで吸収）"
CALLS=0; ATTEMPTS_TO_FAIL=1
rc=0
_verify_with_retry dummy_verify >/dev/null 2>&1 || rc=$?
check "1回目失敗→2回目成功: 戻り値が成功(0)" "0" "$rc"
check "1回目失敗→2回目成功: 検証コマンドは2回呼ばれる" "2" "$CALLS"

# --- ケース2: 常に失敗 → 失敗扱い（exit 3 相当） ---
echo ""
echo "ケース2: 常に失敗 → 失敗扱い（非0戻り＝呼び出し側で exit 3）"
CALLS=0; ATTEMPTS_TO_FAIL=99
rc=0
_verify_with_retry dummy_verify >/dev/null 2>&1 || rc=$?
check "常に失敗: 戻り値が失敗(非0)" "1" "$rc"

# --- ケース3: 試行回数が2回を超えない（恒久 FAIL でも最大2回） ---
echo ""
echo "ケース3: 試行回数の上限（恒久 FAIL でも最大2回しか呼ばれない）"
# ケース2で CALLS は最終的に 2 のはず（同条件・常に失敗）。
check "常に失敗: 検証コマンドの呼び出しは最大2回" "2" "$CALLS"

# --- ケース4: 1回目で成功 → リトライせず1回のみ（通常経路の回帰） ---
echo ""
echo "ケース4: 1回目で成功 → リトライせず1回のみ呼ばれる（通常展開の回帰防止）"
CALLS=0; ATTEMPTS_TO_FAIL=0
rc=0
_verify_with_retry dummy_verify >/dev/null 2>&1 || rc=$?
check "1回目成功: 戻り値が成功(0)" "0" "$rc"
check "1回目成功: 検証コマンドは1回のみ呼ばれる（無駄なリトライ無し）" "1" "$CALLS"

# --- ケース5: 1回目失敗時に「再試行する」旨のログが出る ---
echo ""
echo "ケース5: 1回目失敗時の再試行ログ"
CALLS=0; ATTEMPTS_TO_FAIL=1
retry_log="$(_verify_with_retry dummy_verify 2>&1 >/dev/null)"
case "$retry_log" in
  *"再試行します"*) check "1回目失敗時に再試行ログを出す" "yes" "yes" ;;
  *)               check "1回目失敗時に再試行ログを出す" "yes" "no" ;;
esac

# 1回目から成功した場合は再試行ログを出さないこと。
CALLS=0; ATTEMPTS_TO_FAIL=0
ok_log="$(_verify_with_retry dummy_verify 2>&1 >/dev/null)"
case "$ok_log" in
  *"再試行します"*) check "1回目成功時は再試行ログを出さない" "no" "yes" ;;
  *)               check "1回目成功時は再試行ログを出さない" "no" "no" ;;
esac

# --- 結果 ---
echo ""
echo "================================"
echo "リトライ単体テスト結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL PASS ✓" && exit 0 || echo "FAILED ✗" && exit 1
