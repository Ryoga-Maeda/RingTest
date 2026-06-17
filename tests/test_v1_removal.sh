#!/usr/bin/env bash
# tests/test_v1_removal.sh — §11.2 v1 削除 PR の契約テスト
#
# v1 アーキテクチャの主要ファイルが削除されていることを検査する。
# §11.2 第1段 (PR #3): 6 体の v1 agent .md
# §11.2 R-1 (本 PR): .claude/sprint/RULES.md 削除 + test_isolation.sh 改修
#
# 削除残 (本テストの将来拡張対象 / 別 PR で順次追加):
#   - scripts/sprint-runner.sh 等の v1 専用スクリプト (R-2 で依存監査の上削除)
#   - .claude/commands/sprint-start.md の v1 script 参照 (R-2 と連動)
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PASS=0
FAIL=0

REMOVED_V1_AGENTS=(
  ".claude/agents/orchestrator.md"
  ".claude/agents/planner.md"
  ".claude/agents/generator.md"
  ".claude/agents/worker.md"
  ".claude/agents/reviewer.md"
  ".claude/agents/evaluator.md"
)

V2_REPLACEMENTS=(
  ".claude/agents/orchestrator-v2.md"
  ".claude/agents/phase/clarifier.md"
  ".claude/agents/phase/designer.md"
  ".claude/agents/phase/decomposer.md"
  ".claude/agents/execution/generator.md"
  ".claude/agents/execution/worker.md"
  ".claude/agents/execution/reviewer.md"
  ".claude/agents/execution/evaluator.md"
)

echo "=== test_v1_removal.sh (§11.2 v1 削除契約) ==="

echo "--- v1 agent ファイル群が削除されていること ---"
for f in "${REMOVED_V1_AGENTS[@]}"; do
  if [ ! -e "$f" ]; then
    PASS=$((PASS+1)); echo "  PASS: $f が存在しない"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $f がまだ存在する"
  fi
done

echo "--- V2 置換ファイルが存在すること ---"
for f in "${V2_REPLACEMENTS[@]}"; do
  if [ -f "$f" ]; then
    PASS=$((PASS+1)); echo "  PASS: $f が存在 (V2 置換確認)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $f が無い (V2 置換が不完全)"
  fi
done

echo "--- R-2a〜b: v1 ランナー/ヘルパ/レポートスクリプトと関連テストが削除されていること ---"
REMOVED_V1_SCRIPTS=(
  "scripts/approve-gate.sh"
  "scripts/sprint-runner.sh"
  "scripts/cloud-kickoff.sh"
  "scripts/sprint-deactivate.sh"
  "scripts/sprint-next.sh"
  "scripts/cost-report.sh"
  "scripts/reopen-task.sh"
  "scripts/gc-state.sh"
  "scripts/gen-report.sh"
  "scripts/effective-parallelism.sh"
  "scripts/gen-checkpoint.sh"
  "scripts/run-integration-tests.sh"
  "scripts/integrate.sh"
)
REMOVED_V1_TESTS=(
  "tests/test_runner_loop.sh"
  "tests/test_runner_stall.sh"
  "tests/test_cloud_kickoff.sh"
  "tests/test_sprint_deactivate.sh"
  "tests/test_sprint_next.sh"
  "tests/test_cost_report.sh"
  "tests/test_reopen_task.sh"
  "tests/test_gc_size.sh"
  "tests/test_effective_parallelism.sh"
  "tests/e2e_parallel_execute.sh"
  "tests/test_gen_checkpoint.sh"
  "tests/test_run_integration_tests.sh"
  "tests/test_integrate_failure_classification.sh"
  "tests/test_worktree_integrate_consistency.sh"
  "tests/e2e_integration.sh"
)
for f in "${REMOVED_V1_SCRIPTS[@]}" "${REMOVED_V1_TESTS[@]}"; do
  if [ ! -e "$f" ]; then
    PASS=$((PASS+1)); echo "  PASS: $f が存在しない"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $f がまだ存在する"
  fi
done

echo "--- v1 RULES.md が削除されていること (R-1) ---"
if [ ! -e ".claude/sprint/RULES.md" ]; then
  PASS=$((PASS+1)); echo "  PASS: .claude/sprint/RULES.md が存在しない"
else
  FAIL=$((FAIL+1)); echo "  FAIL: .claude/sprint/RULES.md がまだ存在する"
fi

echo "--- V2 規律が L1 フレームワークヘッダに移転されていること ---"
L1_HEADER=".claude/agents/_prefix/L1-framework-header.md"
if [ -f "$L1_HEADER" ]; then
  PASS=$((PASS+1)); echo "  PASS: $L1_HEADER が存在"
  for r in R0 R1 R2 R3 R4 R5 R6; do
    if grep -qw "$r" "$L1_HEADER"; then
      PASS=$((PASS+1)); echo "  PASS: L1 ヘッダに $r が含まれる"
    else
      FAIL=$((FAIL+1)); echo "  FAIL: L1 ヘッダに $r が含まれない"
    fi
  done
  if grep -q "R3'" "$L1_HEADER"; then
    PASS=$((PASS+1)); echo "  PASS: L1 ヘッダに R3' が含まれる"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: L1 ヘッダに R3' が含まれない"
  fi
else
  FAIL=$((FAIL+1)); echo "  FAIL: $L1_HEADER が存在しない (V2 規律の置き場が無い)"
fi

echo "--- v2_active 既定値が true ---"
default=$(grep -E '\.v2_active\s*=\s*\(\.v2_active\s*//\s*(true|false)\)' scripts/migrate-state-v2.sh 2>/dev/null | grep -oE '(true|false)' | head -1)
if [ "$default" = "true" ]; then
  PASS=$((PASS+1)); echo "  PASS: migrate-state-v2.sh の v2_active 既定値が true"
else
  FAIL=$((FAIL+1)); echo "  FAIL: migrate-state-v2.sh の v2_active 既定値=$default (期待: true)"
fi

echo ""
echo "Total: pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
