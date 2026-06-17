#!/usr/bin/env bash
# .claude/sprint/hooks/pre-tool-use.sh — V2 PreToolUse(Bash) フック
#
# 目的:
#   V2 アクティブ時の R6 強制（worker/executor/phase 系エージェントが git / git worktree / gh を
#   直接実行することを deny する）を pre-tool-use-bash-v2.sh に委譲する。
#
# 構成:
#   v1 既存の pre-task.sh（policy/checks/*.sh のディスパッチャ）はそのまま残置。
#   settings.json の PreToolUse(Bash) には pre-task.sh と本フックの 2 件を並列登録する。
#   Claude Code は同一 matcher の hooks をすべて評価し、いずれかが deny を返せばブロックする。
#
# 不変条件:
#   - v2_active != true のときは silent exit 0（v1 並走に影響しない）
#   - stdin は pre-tool-use-bash-v2.sh が再消費するため、exec で渡す
set -euo pipefail

# v2_active のみ動作
if [ -f sprint/state.json ] && [ "$(jq -r '.v2_active // false' sprint/state.json 2>/dev/null)" = "true" ]; then
  # stdin をそのまま pre-tool-use-bash-v2.sh に引き継ぐ（exec で本プロセスを置換）
  exec bash .claude/sprint/hooks/pre-tool-use-bash-v2.sh
fi

exit 0
