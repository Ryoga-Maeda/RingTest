#!/usr/bin/env bash
set -euo pipefail
CONFIG=sprint/agents.config.json

if [ ! -f "$CONFIG" ]; then
  echo "ERR: $CONFIG not found" >&2
  exit 1
fi

current=$(jq -r '.schema_version // 1' "$CONFIG")
target=2

if [ "$current" = "$target" ]; then
  echo "agents.config.json schema_version=$current is up to date"
  exit 0
fi

tmp=$(mktemp)

# v1 → v2 migration (旧 "model" だけ持っていた agents に effort を補完など)
if [ "$current" = "1" ] && [ "$target" = "2" ]; then
  jq '
    .schema_version = 2 |
    .defaults = (.defaults // { model: "sonnet", effort: "high" }) |
    .model_versions = (.model_versions // { opus: "latest", sonnet: "latest", haiku: "latest", fable: "latest" }) |
    .policy = (.policy // { allow_max_effort_for: [], warn_below_recommended: true, warn_non_latest_version: true })
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  echo "migrated agents.config.json: schema_version $current → $target"
  exit 0
fi

echo "ERR: no migration path from $current to $target" >&2
exit 1
