#!/usr/bin/env bash
# サブエージェント heartbeat 監視: T1 (既定 30 分) を超えた heartbeat を検知し
# state.json.subagent_health に書き込む。
set -euo pipefail
STATE=sprint/state.json
[ -f "$STATE" ] || exit 0

T1_MS=${SPRINT_HEARTBEAT_T1_MS:-1800000}
NOW_MS=$(($(date +%s%N) / 1000000))

# subagent_heartbeats の各エントリを走査
agents=$(jq -r '.subagent_heartbeats // {} | keys[]' "$STATE")

detected=()
for a in $agents; do
  started=$(jq -r --arg k "$a" '.subagent_heartbeats[$k].started_at // 0' "$STATE")
  age=$((NOW_MS - started))
  if [ "$age" -gt "$T1_MS" ] && [ "$started" -gt "0" ]; then
    detected+=("$a")
  fi
done

if [ "${#detected[@]}" -gt 0 ]; then
  tmp=$(mktemp)
  ( flock -x 9
    jq_filter=""
    for a in "${detected[@]}"; do
      jq_filter+=" | .subagent_health[\"$a\"] = { t1_timeout_at: ${NOW_MS}, started_at: (.subagent_heartbeats[\"$a\"].started_at // 0) }"
    done
    jq ". ${jq_filter}" "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  ) 9<"$STATE"
  for a in "${detected[@]}"; do
    echo "T1 detected: $a"
  done
fi
