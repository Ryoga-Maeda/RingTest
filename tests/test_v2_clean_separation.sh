#!/usr/bin/env bash
# V2 分離テスト (§11.2 v1 削除後版):
#   v1 agent ファイル群が削除済みであることと、V2 のサブディレクトリ構成が
#   所定の配置にあることを確認する。
#   削除前の本テストは「v1 ファイルが温存されていること」を assert していたが、
#   §11.2 v1 削除 PR により v1 並走を終了したため、契約を反転させた。
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

fail=0

# v1 ファイルが削除されていることを確認 (§11.2 で削除済み)
for f in \
  .claude/agents/orchestrator.md \
  .claude/agents/planner.md \
  .claude/agents/generator.md \
  .claude/agents/worker.md \
  .claude/agents/reviewer.md \
  .claude/agents/evaluator.md; do
  if [ -e "$f" ]; then
    echo "FAIL: v1 file should be removed but still exists: $f"
    fail=1
  fi
done

# .claude/agents 直下の md は V2 の *-v2.md のみ許可 (v1 命名は禁止)
if [ -d .claude/agents ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    bn=$(basename "$f")
    case "$bn" in
      orchestrator.md|planner.md|generator.md|worker.md|reviewer.md|evaluator.md)
        echo "FAIL: v1 md file should be removed: $f"
        fail=1
        ;;
      *-v2.md) ;;
      *)
        echo "WARN: unknown md at agents root: $f"
        ;;
    esac
  done < <(find .claude/agents -maxdepth 1 -name '*.md' 2>/dev/null)
fi

# V2 サブディレクトリの存在確認
for d in \
  .claude/agents/phase \
  .claude/agents/infra \
  .claude/agents/execution \
  .claude/agents/_prefix; do
  if [ ! -d "$d" ]; then
    echo "FAIL: missing V2 dir $d"
    fail=1
  fi
done

if [ $fail -eq 0 ]; then
  echo "PASS: test_v2_clean_separation"
fi
exit $fail
