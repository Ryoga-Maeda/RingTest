#!/usr/bin/env bash
# tests/test_five_consecutive_sprints.sh — §11.1 統合検証 (1) 5 連続スプリント緑検証
#
# 目的:
#   §11.1 #1 「v2_active=true でテスト用スプリントを 5 回連続成功させる」を
#   テスト環境で実行可能な形で代替検証する。
#
#   本来は実 LLM サブエージェントが各フェーズを実走するが、テスト環境では
#   tests/e2e_implement_then_improve.sh をモック駆動の「1 スプリント完走」と
#   みなし、それを 5 回連続で実行することで以下を担保する:
#
#   - 冪等性: phase-advance-{apply,eval-next-*}.sh が複数回実行で同じ結論を返す
#   - 状態漏れなし: 1 サイクル目で投入したファイル/状態が 2 サイクル目以降の
#     セットアップに影響しない (e2e 内で tmpdir を新規作成しているため)
#   - 累積失敗なし: 5 連続で 0 fail
#   - 性能退行なし: 1 サイクル <30 秒以内
#
# 検証範囲外 (本テストで担保しない):
#   - 実 LLM 応答の安定性 (これは本番運用での観察項目)
#   - subagent_health.heartbeat の T1 タイムアウト挙動 (test_hook_heartbeat.sh で担保)
#   - サブエージェント quarantine 経路 (test_subagent_quarantine_bypass.sh で担保)
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
E2E="$SCRIPT_DIR/e2e_implement_then_improve.sh"

[ -x "$E2E" ] || { echo "FAIL: $E2E not executable"; exit 1; }

CYCLES=5
PER_CYCLE_BUDGET_SEC=30

PASS=0
FAIL=0
total_start=$(date +%s)

echo "=== test_five_consecutive_sprints.sh (§11.1) ==="
echo "  cycles=$CYCLES, per-cycle budget=${PER_CYCLE_BUDGET_SEC}s"
echo ""

for i in $(seq 1 "$CYCLES"); do
  echo "--- cycle $i/$CYCLES ---"
  cycle_start=$(date +%s)
  log=$(mktemp)
  if bash "$E2E" > "$log" 2>&1; then
    cycle_end=$(date +%s)
    elapsed=$((cycle_end - cycle_start))
    # 「Total: pass=N fail=0」を確認
    if grep -qE "Total: pass=[0-9]+ fail=0" "$log"; then
      asserts=$(grep -oE "pass=[0-9]+" "$log" | tail -1 | cut -d= -f2)
      if [ "$elapsed" -le "$PER_CYCLE_BUDGET_SEC" ]; then
        PASS=$((PASS+1))
        echo "  PASS: cycle $i green (asserts=$asserts, ${elapsed}s <= ${PER_CYCLE_BUDGET_SEC}s)"
      else
        FAIL=$((FAIL+1))
        echo "  FAIL: cycle $i 予算超過 (${elapsed}s > ${PER_CYCLE_BUDGET_SEC}s)"
      fi
    else
      FAIL=$((FAIL+1))
      echo "  FAIL: cycle $i exit 0 だが Total 行が確認できない"
      tail -5 "$log" | sed 's/^/    /'
    fi
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: cycle $i E2E が exit 非0"
    tail -10 "$log" | sed 's/^/    /'
  fi
  rm -f "$log"
done

total_end=$(date +%s)
total_elapsed=$((total_end - total_start))

echo ""
echo "Total: pass=$PASS fail=$FAIL (合計 ${total_elapsed}s)"
[ "$FAIL" = "0" ]
