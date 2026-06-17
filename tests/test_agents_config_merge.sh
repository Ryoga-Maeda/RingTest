#!/usr/bin/env bash
# test_agents_config_merge.sh
# frontmatter < config < local の優先順位検証
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MERGE="$REPO_ROOT/scripts/agents-config-merge.sh"
[ -x "$MERGE" ] || { echo "FAIL: merge not exec"; exit 1; }

fail=0
pass=0

# Case 1: agents.local.json で agent の model を上書き
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint" "$tmpdir/.claude/sprint" "$tmpdir/scripts"

# catalog
cp "$REPO_ROOT/.claude/sprint/model-catalog.json" "$tmpdir/.claude/sprint/"
# config
cp "$REPO_ROOT/sprint/agents.config.json" "$tmpdir/sprint/"

# local で worker.model を sonnet (元は opus)
cat > "$tmpdir/sprint/agents.local.json" <<'EOF'
{
  "agents": {
    "worker": { "model": "sonnet", "effort": "medium" }
  }
}
EOF

# scripts/ を symlink
ln -sf "$REPO_ROOT/scripts/agents-config-merge.sh" "$tmpdir/scripts/agents-config-merge.sh"

(cd "$tmpdir" && bash scripts/agents-config-merge.sh >/dev/null)

if [ ! -f "$tmpdir/sprint/.agents.merged.json" ]; then
  fail=$((fail+1)); echo "  FAIL: merged file not created"
else
  worker_model=$(jq -r '.agents.worker.model_family' "$tmpdir/sprint/.agents.merged.json")
  worker_effort=$(jq -r '.agents.worker.effort' "$tmpdir/sprint/.agents.merged.json")
  if [ "$worker_model" = "sonnet" ] && [ "$worker_effort" = "medium" ]; then
    pass=$((pass+1)); echo "  PASS: local override applied"
  else
    fail=$((fail+1)); echo "  FAIL: local override not applied (model=$worker_model effort=$worker_effort)"
  fi
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
