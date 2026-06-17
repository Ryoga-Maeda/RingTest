#!/usr/bin/env bash
# .claude/sprint/hooks/pre-tool-use-task.sh — V2 PreToolUse(Task) フック
#
# 目的:
#   Task ツール（subagent_type 指定の Agent 呼び出し）起動直前に、
#   起動した subagent_type の started_at (epoch ms) を state.json.subagent_heartbeats へ書き込む。
#   これにより scripts/check-heartbeats.sh が T1 超過の浮遊サブエージェントを検知でき、
#   stop_reason: None で取り残されたオーファンを後段で殺せる
#   （V2_ARCHITECTURE_DESIGN.md §5.7.2 Layer 2）。
#
# 不変条件:
#   - v2_active != true のときは silent exit 0（v1 並走へ影響しない）
#   - subagent_type が空（= Task 以外 / 不正入力）でも silent exit 0
#   - 書込スキーマは check-heartbeats.sh / tests/test_subagent_timeout.sh と一致:
#       { subagent_heartbeats: { <agent>: { started_at: <ms> } } }

set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_guard.sh" 2>/dev/null || exit 0
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_state.sh"

input=$(cat)
agent=$(echo "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")
[ -n "$agent" ] || exit 0

# v2 非アクティブなら触らない（v1 経路の state.json を汚さない）。
if [ "$(jq -r '.v2_active // false' "$STATE_FILE" 2>/dev/null)" != "true" ]; then
  exit 0
fi

# epoch ms（check-heartbeats.sh:9 と同じ式）。
now_ms=$(($(date +%s%N) / 1000000))

# 同一 agent の再起動でも started_at を更新する（T1 計測は最新起動からの経過で判定）。
update_state \
  '.subagent_heartbeats[$a] = { started_at: ($t | tonumber) }' \
  --arg a "$agent" --arg t "$now_ms" || true

exit 0
