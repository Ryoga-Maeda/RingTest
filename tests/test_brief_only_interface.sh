#!/usr/bin/env bash
# designer / decomposer は IMPROVE_FINDINGS.md を参照せず BRIEF のみを入力にする (T-C.11)
# Wave C 時点では designer / decomposer の md は未実装の可能性があるため、
# ファイル存在時のみ検査・無ければスキップ扱い (PASS)。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

fail=0
pass=0

for f in "$REPO_ROOT/.claude/agents/phase/designer.md" "$REPO_ROOT/.claude/agents/phase/decomposer.md"; do
  if [ ! -f "$f" ]; then
    pass=$((pass+1)); echo "  SKIP: $f not yet implemented (Wave D)"
    continue
  fi
  # IMPROVE_FINDINGS.md への参照が無いこと
  if grep -q "IMPROVE_FINDINGS" "$f"; then
    fail=$((fail+1)); echo "  FAIL: $f references IMPROVE_FINDINGS.md (should use BRIEF only)"
  else
    pass=$((pass+1)); echo "  PASS: $f does not reference IMPROVE_FINDINGS"
  fi
done

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
