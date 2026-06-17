#!/usr/bin/env bash
# test_model_version_resolve.sh
# model_versions.opus="latest" → catalog の latest ID へ解決
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MERGE="$REPO_ROOT/scripts/agents-config-merge.sh"

fail=0
pass=0

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint" "$tmpdir/.claude/sprint" "$tmpdir/scripts"
cp "$REPO_ROOT/.claude/sprint/model-catalog.json" "$tmpdir/.claude/sprint/"
cp "$REPO_ROOT/sprint/agents.config.json" "$tmpdir/sprint/"
ln -sf "$REPO_ROOT/scripts/agents-config-merge.sh" "$tmpdir/scripts/agents-config-merge.sh"

# model_versions.opus="latest" → catalog の latest ID へ解決
(cd "$tmpdir" && bash scripts/agents-config-merge.sh >/dev/null)
resolved=$(jq -r '.model_versions_resolved.opus' "$tmpdir/sprint/.agents.merged.json")
catalog_latest=$(jq -r '.families.opus.latest' "$tmpdir/.claude/sprint/model-catalog.json")
if [ "$resolved" = "$catalog_latest" ]; then
  pass=$((pass+1)); echo "  PASS: opus 'latest' resolved to $resolved"
else
  fail=$((fail+1)); echo "  FAIL: got $resolved, expected $catalog_latest"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
