#!/usr/bin/env bash
# bug-hunter の規約検査（静的検査） (T-C.8)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BH="$REPO_ROOT/.claude/agents/infra/bug-hunter.md"
BH_YAML="$REPO_ROOT/.claude/sprint/output-contracts/bug-hunter.yaml"

[ -f "$BH" ] || { echo "FAIL: bug-hunter.md not found"; exit 1; }
[ -f "$BH_YAML" ] || { echo "FAIL: bug-hunter.yaml not found"; exit 1; }

fail=0
pass=0

# 1) 本文に「原因や直し方は考えてはいけない」を含む
if grep -q "原因や直し方は考えてはいけない" "$BH"; then
  pass=$((pass+1)); echo "  PASS: bug-hunter.md contains '原因や直し方は考えてはいけない'"
else
  fail=$((fail+1)); echo "  FAIL: directive missing"
fi

# 2) yaml の forbidden_patterns に「原因は」「修正方法」「P1」「P2」「P3」が含まれる
for term in "原因は" "修正方法" "P1" "P2" "P3"; do
  if grep -qF "$term" "$BH_YAML"; then
    pass=$((pass+1)); echo "  PASS: bug-hunter.yaml forbids '$term'"
  else
    fail=$((fail+1)); echo "  FAIL: bug-hunter.yaml missing '$term' in forbidden_patterns"
  fi
done

# 3) bug-hunter は原因分析を含まない出力契約か確認 (Evaluator 採点との関係セクションへの言及があるか)
if grep -q "Evaluator 採点" "$BH"; then
  pass=$((pass+1)); echo "  PASS: bug-hunter.md references Evaluator 採点"
else
  fail=$((fail+1)); echo "  FAIL: Evaluator 採点 not referenced"
fi

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
