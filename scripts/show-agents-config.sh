#!/usr/bin/env bash
set -euo pipefail
MERGED=sprint/.agents.merged.json

if [ ! -f "$MERGED" ]; then
  echo "ERR: $MERGED not found. Run scripts/agents-config-merge.sh first" >&2
  exit 1
fi

echo "=== model_versions_resolved ==="
jq -r '.model_versions_resolved | to_entries[] | "\(.key)\t\(.value)"' "$MERGED" | column -t -s$'\t'

echo ""
echo "=== agents ==="
printf "%-20s %-12s %-30s %-8s\n" "name" "family" "model_id" "effort"
printf "%-20s %-12s %-30s %-8s\n" "----" "------" "--------" "------"
jq -r '.agents | to_entries[] | "\(.key)\t\(.value.model_family)\t\(.value.model_id)\t\(.value.effort)"' "$MERGED" | \
  while IFS=$'\t' read -r name fam mid eff; do
    printf "%-20s %-12s %-30s %-8s\n" "$name" "$fam" "$mid" "$eff"
  done
