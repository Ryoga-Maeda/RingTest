#!/usr/bin/env bash
# V1/V2 クロス参照禁止テスト:
# V2 ファイル群が v1 専用パス（.claude/agents/orchestrator.md など）を
# ファイル内で参照していないことを grep で検査する。
# 例外: §0.1 #3 で参照許可された v1 スクリプト 4 本（.sh）は対象外。
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

V1_FORBIDDEN_REFS=(
  ".claude/agents/orchestrator.md"
  ".claude/agents/planner.md"
  ".claude/agents/generator.md"
  ".claude/agents/worker.md"
  ".claude/agents/reviewer.md"
  ".claude/agents/evaluator.md"
)

fail=0

# V2 候補ファイルを列挙（サブディレクトリ配下＋agents 直下の *-v2.md）
mapfile -t V2_FILES < <(
  {
    find .claude/agents/phase .claude/agents/infra .claude/agents/execution .claude/agents/_prefix -type f -name '*.md' 2>/dev/null
    find .claude/agents -maxdepth 1 -type f -name '*-v2.md' 2>/dev/null
  } | sort -u
)

for v2 in "${V2_FILES[@]}"; do
  [ -f "$v2" ] || continue
  for ref in "${V1_FORBIDDEN_REFS[@]}"; do
    if grep -q "$ref" "$v2"; then
      echo "FAIL: $v2 references v1 file $ref"
      fail=1
    fi
  done
done

if [ $fail -eq 0 ]; then
  echo "PASS: test_v1_v2_no_cross_ref"
fi
exit $fail
