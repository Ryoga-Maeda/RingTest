#!/usr/bin/env bash
# tests/test_repo_mgr_single_window.sh — repo-mgr 唯一の git 書込窓口検査
#
# 目的:
#   V2 で新規追加された orchestrator-v2 / infra (repo-mgr.md と worktree-mgr.md を除く) /
#   phase / execution エージェント定義および V2 新規スクリプトから、
#   `git push` / `git commit` / `git add` / `git reset` / `git branch` / `git checkout` /
#   `git merge` / `git rebase` を直接呼ぶ箇所が無いことを grep で検査する。
#
# 例外:
#   - 既存 v1 scripts は対象外（§0.1 残置スクリプト + その他 v1 既存スクリプト）。
#   - repo-mgr.md / worktree-mgr.md は git 書込を許可された窓口のため除外。
#   - コメント行（`#` で始まる行）は無視。
#
# exit code:
#   0 = 全 V2 新規ファイルが clean
#   1 = 1 件でも直接呼出を検出
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

fail=0
pass=0

# V2 新規スクリプト一覧
V2_NEW_SCRIPTS=(
  "scripts/phase-advance-eval.sh"
  "scripts/phase-advance-apply.sh"
  "scripts/phase-advance-eval-next-phase.sh"
  "scripts/phase-advance-eval-next-sub.sh"
  "scripts/migrate-state-v2.sh"
  "scripts/persona-init-v2.sh"
  "scripts/verify-output-contract.sh"
  "scripts/quarantine-agent.sh"
  "scripts/check-heartbeats.sh"
)

# V2 新規エージェント（repo-mgr.md と worktree-mgr.md は除外）
V2_AGENTS=(
  ".claude/agents/orchestrator-v2.md"
  ".claude/agents/infra/consistency-mgr.md"
  ".claude/agents/infra/escalation-mgr.md"
  ".claude/agents/infra/recovery-mgr.md"
)

# 禁止パターン: git push / commit / add / reset / branch / checkout / merge / rebase
FORBIDDEN_REGEX='(^|[^a-zA-Z_])git[[:space:]]+(push|commit|add|reset|branch|checkout|merge|rebase)'

check_file() {
  local f="$1"
  if [ ! -f "$f" ]; then
    pass=$((pass+1)); echo "  SKIP: $f not present"
    return
  fi
  # コメント行（先頭が # の行）を除外したうえで grep
  local hits
  hits=$(grep -nE "$FORBIDDEN_REGEX" "$f" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
  if [ -n "$hits" ]; then
    fail=$((fail+1))
    echo "  FAIL: $f contains direct git command:"
    echo "$hits" | sed 's/^/    /'
  else
    pass=$((pass+1)); echo "  PASS: $f clean"
  fi
}

echo "=== V2 新規スクリプト ==="
for f in "${V2_NEW_SCRIPTS[@]}"; do check_file "$f"; done

echo "=== V2 新規エージェント ==="
for f in "${V2_AGENTS[@]}"; do check_file "$f"; done

# phase / execution ディレクトリ配下も再帰検査（将来追加のため）
echo "=== phase / execution エージェント（将来追加用） ==="
for d in .claude/agents/phase .claude/agents/execution; do
  [ -d "$d" ] || { echo "  SKIP: $d not present"; continue; }
  while IFS= read -r f; do check_file "$f"; done < <(find "$d" -name '*.md')
done

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
