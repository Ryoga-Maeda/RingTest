#!/usr/bin/env bash
# .claude/sprint/hooks/_guard.sh
# 全フックが冒頭で source する。非アクティブなら呼び出し元フックを即終了。

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$ROOT/sprint/state.json"

sprint_active() {
  [ -f "$STATE_FILE" ] || return 1
  local s
  s=$(jq -r '.run_state // "OFF"' "$STATE_FILE" 2>/dev/null)
  # run_state 集合: OFF / RUNNING / COMPLETE（終端正常）/ ABORTED（終端致命）。
  # フックが効くアクティブ状態は RUNNING のみ。終端（COMPLETE/ABORTED）と OFF は no-op。
  case "$s" in
    RUNNING) return 0 ;;
    *) return 1 ;;
  esac
}

sprint_active || exit 0
# ここを抜けた場合のみ、呼び出し元フックの処理が継続される
