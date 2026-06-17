#!/usr/bin/env bash
# .claude/sprint/policy/checks/agents_config_validate.sh — Wave E (T-E.11)
#
# 目的:
#   pre-commit / PreToolUse(Bash git commit) のチェーンから呼ばれ、
#   sprint/agents.config.json または sprint/agents.local.json が存在する場合に
#   scripts/validate-agents-config.sh を実行する。検証 NG 時は commit を止める。
#
# 呼出:
#   bash .claude/sprint/policy/checks/agents_config_validate.sh
#
# 終了コード:
#   0  : 検証 OK / 対象ファイル無し
#   1  : 検証 NG（commit 中止）
#
# 既存 v1 pre-commit hook（または PreToolUse 経由の commit チェック群）が
# このスクリプトをチェーン呼出する想定。直接 git の .git/hooks/pre-commit を
# 書き換えない理由: Claude Code 環境では .git/hooks が共有でない場合があり、
# policy/checks/ 配下にチェッカーを並べて hook 側がループするのが既存規約。
set -euo pipefail

# 検証対象が無ければ no-op で抜ける（v1 既存リポジトリで agents.config を導入していないケース）
if [ ! -f sprint/agents.config.json ] && [ ! -f sprint/agents.local.json ]; then
  exit 0
fi

# validate スクリプトが配置されていない（古い checkout 等）も no-op で抜ける
if [ ! -f scripts/validate-agents-config.sh ]; then
  exit 0
fi

# 実行: NG ならエラーを表示して exit 1（commit 中止）
if ! bash scripts/validate-agents-config.sh 2>&1; then
  echo "ERR: agents config invalid. commit blocked." >&2
  exit 1
fi

exit 0
