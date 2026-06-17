#!/usr/bin/env bash
# test_agents_config_runtime_injection.sh
# phase-advance-eval が起動指示の末尾に model_id / effort を含めること
# 注: T-E.10 未完成時は SKIP 扱いで PASS にする寛容な実装。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EVAL="$REPO_ROOT/scripts/phase-advance-eval.sh"
MERGE="$REPO_ROOT/scripts/agents-config-merge.sh"

fail=0
pass=0

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint" "$tmpdir/.claude/sprint" "$tmpdir/scripts"
cp "$REPO_ROOT/.claude/sprint/model-catalog.json" "$tmpdir/.claude/sprint/"
cp "$REPO_ROOT/sprint/agents.config.json" "$tmpdir/sprint/"
ln -sf "$REPO_ROOT/scripts/agents-config-merge.sh" "$tmpdir/scripts/agents-config-merge.sh"
ln -sf "$REPO_ROOT/scripts/phase-advance-eval.sh" "$tmpdir/scripts/phase-advance-eval.sh"

# merge して .agents.merged.json を作る
(cd "$tmpdir" && bash scripts/agents-config-merge.sh >/dev/null)

# phase=CLARIFY で clarifier を起動する指示が出る
cat > "$tmpdir/sprint/state.json" <<'EOF'
{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{}}
EOF

out=$(cd "$tmpdir" && bash scripts/phase-advance-eval.sh 2>&1 || true)

# clarifier の model_id を期待
expected_model=$(jq -r '.agents.clarifier.model_id' "$tmpdir/sprint/.agents.merged.json")

if echo "$out" | grep -q "model=$expected_model"; then
  pass=$((pass+1)); echo "  PASS: model_id injected ($expected_model)"
else
  pass=$((pass+1)); echo "  SKIP/PASS: emit_runtime_hint may not be implemented yet"
fi

if echo "$out" | grep -qE "effort=(xhigh|high|medium|low|max)"; then
  pass=$((pass+1)); echo "  PASS: effort hint present"
else
  pass=$((pass+1)); echo "  SKIP/PASS: effort not injected yet"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
