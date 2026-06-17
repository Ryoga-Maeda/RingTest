#!/usr/bin/env bash
# investigator BRIEF スキーマの静的検査 (T-C.9)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
INV="$REPO_ROOT/.claude/agents/infra/investigator.md"
INV_YAML="$REPO_ROOT/.claude/sprint/output-contracts/investigator.yaml"
TPL="$REPO_ROOT/sprint/templates/IMPROVE_BRIEF.template.md"

[ -f "$INV" ] || { echo "FAIL: investigator.md missing"; exit 1; }
[ -f "$INV_YAML" ] || { echo "FAIL: investigator.yaml missing"; exit 1; }

fail=0
pass=0

# 必須セクション
for sec in "全体傾向" "修正項目テーブル" "依存・順序ヒント"; do
  if grep -qF "$sec" "$INV"; then
    pass=$((pass+1)); echo "  PASS: investigator.md mentions '$sec'"
  else
    fail=$((fail+1)); echo "  FAIL: investigator.md missing '$sec'"
  fi
  if grep -qF "$sec" "$INV_YAML"; then
    pass=$((pass+1)); echo "  PASS: investigator.yaml required_sections has '$sec'"
  else
    fail=$((fail+1)); echo "  FAIL: investigator.yaml missing required_section '$sec'"
  fi
done

# 修正項目テーブルの必須カラム
for col in "ID" "症状" "根本原因" "影響範囲" "失敗分類" "優先度"; do
  if grep -qF "$col" "$INV"; then
    pass=$((pass+1)); echo "  PASS: column '$col' in investigator.md"
  else
    fail=$((fail+1)); echo "  FAIL: column '$col' missing"
  fi
done

# 優先度値は P1/P2/P3 のみ (本文の例示で他の値が出ていないことを確認)
if grep -qE "P[4-9]|P[0-9]{2,}" "$INV"; then
  fail=$((fail+1)); echo "  FAIL: investigator.md contains non-P1/2/3 priority"
else
  pass=$((pass+1)); echo "  PASS: investigator.md uses only P1/P2/P3"
fi

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
