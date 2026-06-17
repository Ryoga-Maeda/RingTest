#!/usr/bin/env bash
# scripts/quarantine-agent.sh — V2 サブエージェント隔離
#
# 目的:
#   出力契約違反を起こしたサブエージェントを一定時間（+15 分）隔離する。
#   state.json の subagent_health.<agent>.quarantine_until に
#   現在時刻+15 分（epoch ms）を書き込む。
#
# 引数:
#   $1 : agent name（必須）
#
# exit code:
#   0 = 正常書き込み
#   1 = 引数不足 / state.json 不在
#
# 副作用:
#   - sprint/state.json の atomic 更新（flock + mv）
set -euo pipefail

agent="${1:-}"
if [ -z "$agent" ]; then
  echo "ERR: agent name required" >&2
  exit 1
fi

STATE=sprint/state.json
if [ ! -f "$STATE" ]; then
  echo "ERR: state.json not found: $STATE" >&2
  exit 1
fi

NOW_MS=$(($(date +%s%N) / 1000000))
UNTIL_MS=$((NOW_MS + 15 * 60 * 1000))  # +15 分

tmp=$(mktemp)
(
  flock -x 9
  jq --arg a "$agent" \
     --argjson u "$UNTIL_MS" \
     --argjson q "$NOW_MS" '
    .subagent_health = (.subagent_health // {})
    | .subagent_health[$a] = ((.subagent_health[$a] // {}) + {
        quarantine_until: $u,
        quarantined_at: $q
      })
  ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
) 9<"$STATE"

echo "quarantined: $agent until $UNTIL_MS"
