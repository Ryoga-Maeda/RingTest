#!/usr/bin/env bash
# test_agents_config_schema.sh
# validate-agents-config.sh のスキーマ検査
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VALIDATE="$REPO_ROOT/scripts/validate-agents-config.sh"
[ -x "$VALIDATE" ] || { echo "FAIL: validate not exec"; exit 1; }

fail=0
pass=0

# Case 1: 正常設定 → PASS
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint" "$tmpdir/.claude/sprint" "$tmpdir/scripts"
cp "$REPO_ROOT/.claude/sprint/model-catalog.json" "$tmpdir/.claude/sprint/"
cp "$REPO_ROOT/sprint/agents.config.json" "$tmpdir/sprint/"
ln -sf "$REPO_ROOT/scripts/validate-agents-config.sh" "$tmpdir/scripts/validate-agents-config.sh"

set +e
(cd "$tmpdir" && bash scripts/validate-agents-config.sh 2>/dev/null)
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass=$((pass+1)); echo "  PASS: default config valid"
else
  fail=$((fail+1)); echo "  FAIL: default config invalid (rc=$rc)"
fi

# Case 2: 不正 model → FAIL
jq '.agents.worker.model = "invalid_model"' "$tmpdir/sprint/agents.config.json" > "$tmpdir/tmp.json" && mv "$tmpdir/tmp.json" "$tmpdir/sprint/agents.config.json"
set +e
(cd "$tmpdir" && bash scripts/validate-agents-config.sh 2>/dev/null)
rc=$?
set -e
if [ "$rc" != "0" ]; then
  pass=$((pass+1)); echo "  PASS: invalid model rejected"
else
  fail=$((fail+1)); echo "  FAIL: invalid model not rejected"
fi

# Case 3: 不正 effort → FAIL
cp "$REPO_ROOT/sprint/agents.config.json" "$tmpdir/sprint/agents.config.json"
jq '.agents.worker.effort = "invalid_effort"' "$tmpdir/sprint/agents.config.json" > "$tmpdir/tmp.json" && mv "$tmpdir/tmp.json" "$tmpdir/sprint/agents.config.json"
set +e
(cd "$tmpdir" && bash scripts/validate-agents-config.sh 2>/dev/null)
rc=$?
set -e
if [ "$rc" != "0" ]; then
  pass=$((pass+1)); echo "  PASS: invalid effort rejected"
else
  fail=$((fail+1)); echo "  FAIL: invalid effort not rejected"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
