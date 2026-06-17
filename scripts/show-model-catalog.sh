#!/usr/bin/env bash
set -euo pipefail
CATALOG=.claude/sprint/model-catalog.json

if [ ! -f "$CATALOG" ]; then
  echo "ERR: $CATALOG not found" >&2
  exit 1
fi

echo "Model catalog (schema_version=$(jq -r '.schema_version' "$CATALOG"), updated_at=$(jq -r '.updated_at' "$CATALOG"))"
echo ""

for f in $(jq -r '.families | keys[]' "$CATALOG"); do
  latest=$(jq -r --arg f "$f" '.families[$f].latest' "$CATALOG")
  echo "[$f] latest=$latest"
  jq -r --arg f "$f" '.families[$f].versions[] | "  \(.id)\t\(.released)\t\(.notes // "")"' "$CATALOG"
  echo ""
done
