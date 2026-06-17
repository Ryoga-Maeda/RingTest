#!/usr/bin/env bash
# test_agents_config_policy.sh
# max effort を allow_max_effort_for にない agent に指定 → エラー
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

# worker に max effort 指定だが allow_max_effort_for に含まれない
jq '.agents.worker.effort = "max"' "$tmpdir/sprint/agents.config.json" > "$tmpdir/tmp.json" && mv "$tmpdir/tmp.json" "$tmpdir/sprint/agents.config.json"

set +e
(cd "$tmpdir" && bash scripts/validate-agents-config.sh 2>/dev/null)
rc=$?
set -e
if [ "$rc" != "0" ]; then
  pass=$((pass+1)); echo "  PASS: max effort blocked when not in allow_max_effort_for"
else
  fail=$((fail+1)); echo "  FAIL: max effort not blocked"
fi

# allow_max_effort_for に追加 → PASS
jq '.policy.allow_max_effort_for = ["worker"]' "$tmpdir/sprint/agents.config.json" > "$tmpdir/tmp.json" && mv "$tmpdir/tmp.json" "$tmpdir/sprint/agents.config.json"
set +e
(cd "$tmpdir" && bash scripts/validate-agents-config.sh 2>/dev/null)
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass=$((pass+1)); echo "  PASS: max effort allowed when whitelisted"
else
  fail=$((fail+1)); echo "  FAIL: max effort still blocked when whitelisted"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
