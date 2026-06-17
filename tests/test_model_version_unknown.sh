#!/usr/bin/env bash
# test_model_version_unknown.sh
# 未知 ID 指定 → validate FAIL
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VALIDATE="$REPO_ROOT/scripts/validate-agents-config.sh"

fail=0
pass=0

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint" "$tmpdir/.claude/sprint" "$tmpdir/scripts"
cp "$REPO_ROOT/.claude/sprint/model-catalog.json" "$tmpdir/.claude/sprint/"
cp "$REPO_ROOT/sprint/agents.config.json" "$tmpdir/sprint/"
ln -sf "$REPO_ROOT/scripts/validate-agents-config.sh" "$tmpdir/scripts/validate-agents-config.sh"

# 未知 ID 指定 → validate FAIL
jq '.model_versions.opus = "claude-opus-99-99"' "$tmpdir/sprint/agents.config.json" > "$tmpdir/tmp.json" && mv "$tmpdir/tmp.json" "$tmpdir/sprint/agents.config.json"
set +e
(cd "$tmpdir" && bash scripts/validate-agents-config.sh 2>/dev/null)
rc=$?
set -e
if [ "$rc" != "0" ]; then
  pass=$((pass+1)); echo "  PASS: unknown version rejected"
else
  fail=$((fail+1)); echo "  FAIL: unknown version not rejected"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
