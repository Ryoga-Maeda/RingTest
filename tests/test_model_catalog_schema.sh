#!/usr/bin/env bash
# test_model_catalog_schema.sh
# model-catalog.json のスキーマ検証（families.*.latest と versions[].id）
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CATALOG="$REPO_ROOT/.claude/sprint/model-catalog.json"

[ -f "$CATALOG" ] || { echo "FAIL: catalog not found"; exit 1; }

fail=0
pass=0

# families の各系列に latest 必須
for fam in opus sonnet haiku fable; do
  latest=$(jq -r --arg f "$fam" '.families[$f].latest // empty' "$CATALOG")
  if [ -n "$latest" ]; then
    pass=$((pass+1)); echo "  PASS: $fam.latest=$latest"
  else
    fail=$((fail+1)); echo "  FAIL: $fam.latest missing"
  fi
done

# versions に id 必須
families=$(jq -r '.families | keys[]' "$CATALOG")
for fam in $families; do
  cnt=$(jq -r --arg f "$fam" '.families[$f].versions | length' "$CATALOG")
  for i in $(seq 0 $((cnt - 1))); do
    [ "$i" -lt 0 ] && continue
    id=$(jq -r --arg f "$fam" --argjson i "$i" '.families[$f].versions[$i].id // empty' "$CATALOG")
    if [ -n "$id" ]; then
      pass=$((pass+1)); echo "  PASS: $fam.versions[$i].id=$id"
    else
      fail=$((fail+1)); echo "  FAIL: $fam.versions[$i].id missing"
    fi
  done
done

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
