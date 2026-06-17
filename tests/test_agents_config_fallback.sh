#!/usr/bin/env bash
# test_agents_config_fallback.sh
# agents.local.json 欠落でも config だけで動作
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MERGE="$REPO_ROOT/scripts/agents-config-merge.sh"

fail=0
pass=0

# Case 1: agents.local.json 欠落でも config だけで動作
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint" "$tmpdir/.claude/sprint" "$tmpdir/scripts"
cp "$REPO_ROOT/.claude/sprint/model-catalog.json" "$tmpdir/.claude/sprint/"
cp "$REPO_ROOT/sprint/agents.config.json" "$tmpdir/sprint/"
ln -sf "$REPO_ROOT/scripts/agents-config-merge.sh" "$tmpdir/scripts/agents-config-merge.sh"

set +e
(cd "$tmpdir" && bash scripts/agents-config-merge.sh >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" = "0" ] && [ -f "$tmpdir/sprint/.agents.merged.json" ]; then
  pass=$((pass+1)); echo "  PASS: merge works without local.json"
else
  fail=$((fail+1)); echo "  FAIL: merge failed without local.json (rc=$rc)"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
