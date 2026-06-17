#!/usr/bin/env bash
# V2 state.json マイグレーション: v1 既存 state.json に V2 追加フィールドを冪等に補う。
set -euo pipefail
STATE=sprint/state.json
[ -f "$STATE" ] || exit 0

current=$(jq -r '.schema_version // 1' "$STATE")
[ "$current" -ge 2 ] && exit 0   # 冪等: 既に v2 schema

tmp=$(mktemp)
( flock -x 9
  jq '
    .v2_active                   = (.v2_active // true) |
    .sub_phase                   = (.sub_phase // "implement") |
    .improve_iteration           = (.improve_iteration // 0) |
    .phase_advance_last_fired_at = (.phase_advance_last_fired_at // 0) |
    .triage_artifacts            = (.triage_artifacts // { findings_path: null, brief_path: null, p1_count: 0, p2_count: 0, p3_count: 0 }) |
    .subagent_health             = (.subagent_health // {}) |
    .subagent_heartbeats         = (.subagent_heartbeats // {}) |
    .gate_approvals              = (.gate_approvals // {}) |
    .persona                     = (.persona // null) |
    .schema_version              = 2
  ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
) 9<"$STATE"
