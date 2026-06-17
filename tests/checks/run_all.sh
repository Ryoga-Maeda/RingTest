#!/usr/bin/env bash
# tests/checks/run_all.sh — チェックスクリプト単体テストの一括実行
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_FAIL=0
for t in "$DIR"/test_*.sh; do
  echo ""
  if bash "$t"; then :; else TOTAL_FAIL=$((TOTAL_FAIL+1)); fi
done
echo ""
echo "########################################"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "checks 単体テスト: 全 green"
  exit 0
else
  echo "checks 単体テスト: $TOTAL_FAIL ファイルが FAIL"
  exit 1
fi
