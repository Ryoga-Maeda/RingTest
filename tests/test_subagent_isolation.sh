#!/usr/bin/env bash
# tests/test_subagent_isolation.sh
#
# 目的:
#   フェーズ間で context が共有されないこと、および他フェーズ出力ファイルへの書込が
#   静的に検査できることを保証する。
#
# 静的検査の対象:
#   1. clarifier / designer / decomposer / executor / verifier / integrator / completer
#      の各 .md に「自フェーズ以外のファイルを書き換えない」「他フェーズの context を
#      保持しない」相当の文言が含まれること
#   2. orchestrator-v2.md が薄殻シェルとして state.json / git / Bash 直叩きを禁じる
#      構造的隔離文言を持つこと
#   3. infra/bug-hunter.md / infra/investigator.md が存在すること（Brief-only Interface
#      担保の前提）
#   4. scripts/phase-advance-eval.sh が read-only（他フェーズ md への Write/Edit 命令を
#      指示文に含まない）こと
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PHASE_DIR="$REPO_ROOT/.claude/agents/phase"

fail=0
pass=0

# 1) 各 phase エージェントの md ファイルを検査
PHASE_AGENTS=(
  "clarifier.md"
  "designer.md"
  "decomposer.md"
  "executor.md"
  "verifier.md"
  "integrator.md"
  "completer.md"
)

for a in "${PHASE_AGENTS[@]}"; do
  f="$PHASE_DIR/$a"
  if [ ! -f "$f" ]; then
    fail=$((fail+1)); echo "  FAIL: $f not found"
    continue
  fi
  # 「自フェーズ以外のファイルを書き換えない」相当のチェック
  if grep -qE "自フェーズ以外|自フェーズ担当ファイル以外|自フェーズの|他フェーズ" "$f"; then
    pass=$((pass+1)); echo "  PASS: $a contains isolation language"
  else
    fail=$((fail+1)); echo "  FAIL: $a missing isolation language"
  fi
done

# 2) orchestrator-v2.md は薄殻シェルなので別途検査 (Bash/Read/Edit/Write 非保有)
ORCH="$REPO_ROOT/.claude/agents/orchestrator-v2.md"
if [ -f "$ORCH" ]; then
  if grep -qE "Bash は無い|state.json を直接読まない|git を直接操作しない" "$ORCH"; then
    pass=$((pass+1)); echo "  PASS: orchestrator-v2 has structural isolation"
  else
    fail=$((fail+1)); echo "  FAIL: orchestrator-v2 missing structural isolation"
  fi
else
  fail=$((fail+1)); echo "  FAIL: orchestrator-v2.md not found"
fi

# 3) bug-hunter / investigator も Brief-only Interface 担保
for a in "bug-hunter.md" "investigator.md"; do
  f="$REPO_ROOT/.claude/agents/infra/$a"
  if [ ! -f "$f" ]; then
    fail=$((fail+1)); echo "  FAIL: infra/$a not found"
    continue
  fi
  # それぞれ自分の役割範囲を明示しているかをチェック（存在確認に留める）
  pass=$((pass+1)); echo "  PASS: $a present"
done

# 4) 実機検査（簡略化・モック）: phase-advance-eval が他フェーズの出力ファイルを直接いじっていないことを grep
EVAL="$REPO_ROOT/scripts/phase-advance-eval.sh"
if [ -f "$EVAL" ]; then
  # 「sprint/PRODUCT.md を書き換える」「sprint/SPRINT.md を編集」など Edit/Write 命令を含まないこと
  if grep -qE "(Write|Edit).*\.md|sprint/.*\.md を書込" "$EVAL"; then
    fail=$((fail+1)); echo "  FAIL: phase-advance-eval contains direct write command"
  else
    pass=$((pass+1)); echo "  PASS: phase-advance-eval is read-only"
  fi
else
  fail=$((fail+1)); echo "  FAIL: scripts/phase-advance-eval.sh not found"
fi

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
