#!/usr/bin/env bash
# TRIAGE→IMPROVE ゲートの指示文を検査 (T-C.10)
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EVAL="$REPO_ROOT/scripts/phase-advance-eval.sh"
[ -x "$EVAL" ] || { echo "FAIL: eval not exec"; exit 1; }

fail=0
pass=0

# Case 1: P1+P2>0 / gate=false → AskUserQuestion
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint"
cat > "$tmpdir/sprint/state.json" <<'EOF'
{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{},"triage_artifacts":{"p1_count":1,"p2_count":0},"subagent_health":{}}
EOF
: > "$tmpdir/sprint/IMPROVE_FINDINGS.md"
: > "$tmpdir/sprint/IMPROVE_BRIEF.md"
out=$(cd "$tmpdir" && bash "$EVAL" 2>&1)
if echo "$out" | grep -q "AskUserQuestion"; then
  pass=$((pass+1)); echo "  PASS: gate=false → AskUserQuestion"
else
  fail=$((fail+1)); echo "  FAIL: got: $out"
fi

# Case 2: gate=true → clarifier (sub_phase=improve に遷移済み前提なので、ここでは TRIAGE のままで clarifier 起動指示)
cat > "$tmpdir/sprint/state.json" <<'EOF'
{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{"TRIAGE_TO_IMPROVE":true},"triage_artifacts":{"p1_count":1,"p2_count":0},"subagent_health":{}}
EOF
out=$(cd "$tmpdir" && bash "$EVAL" 2>&1)
if echo "$out" | grep -q "clarifier"; then
  pass=$((pass+1)); echo "  PASS: gate=true → clarifier"
else
  fail=$((fail+1)); echo "  FAIL: got: $out"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
