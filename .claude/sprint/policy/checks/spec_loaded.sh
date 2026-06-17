#!/usr/bin/env bash
# R1: 仕様先行強制 — contract.agreed=true かつ SPRINT.md 存在を確認
# exit 0 = 許可 / exit 1 = 拒否（拒否理由を標準出力）/ 判定不能 = exit 1（fail-closed）
#
# 入力（環境変数）: FILE（書込先パス）, STATE_FILE, ROOT

[ -z "${FILE:-}" ] && exit 0    # ファイルパス不明（Bash コマンド等）は対象外

# src/** への Write/Edit のみチェック
case "$FILE" in
  */src/*|src/*) ;;
  *) exit 0 ;;    # src 外は対象外
esac

AGREED=$(jq -r '.contract.agreed // false' "$STATE_FILE" 2>/dev/null)
if [ "$AGREED" != "true" ]; then
  echo "R1 違反: contract.agreed が '$AGREED' です。SPRINT.md でスプリント契約を先に合意してください"
  exit 1
fi

SPRINT_FILE="${ROOT}/sprint/SPRINT.md"
if [ ! -f "$SPRINT_FILE" ]; then
  echo "R1 違反: sprint/SPRINT.md が存在しません"
  exit 1
fi
exit 0
