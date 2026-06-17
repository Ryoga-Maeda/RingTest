#!/usr/bin/env bash
# improve_iteration の上限 (=3) を超えると ESCALATION に遷移する (T-C.12)
#
# 注意:
#   - apply.sh は cwd 相対で scripts/phase-advance-eval-next-{phase,sub}.sh を呼び出すため、
#     tmpdir に scripts/ 配下を複製してから cd して実行する。
#   - state.json のスキーマは「triage.P1 / triage.P2」（eval-next-phase.sh が参照）。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EVAL="$REPO_ROOT/scripts/phase-advance-eval.sh"
APPLY="$REPO_ROOT/scripts/phase-advance-apply.sh"
[ -x "$EVAL" ] || { echo "FAIL: eval not exec"; exit 1; }
[ -x "$APPLY" ] || { echo "FAIL: apply not exec"; exit 1; }

setup_workdir() {
  local d="$1"
  mkdir -p "$d/sprint" "$d/scripts"
  for s in phase-advance-apply.sh phase-advance-eval-next-phase.sh phase-advance-eval-next-sub.sh plan-waves.sh; do
    cp "$REPO_ROOT/scripts/$s" "$d/scripts/$s"
    chmod +x "$d/scripts/$s"
  done
}

fail=0
pass=0

# Case 1: improve_iteration=3, P1+P2>0 → ESCALATION (apply の遷移)
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'EOF'
{"phase":"COMPLETE","sub_phase":"improve","gate_approvals":{},"triage":{"P1":1,"P2":0},"improve_iteration":3,"subagent_health":{}}
EOF
(cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null)
phase=$(jq -r '.phase' "$tmpdir/sprint/state.json")
if [ "$phase" = "ESCALATION" ]; then
  pass=$((pass+1)); echo "  PASS: improve_iteration=3 → ESCALATION"
else
  fail=$((fail+1)); echo "  FAIL: got phase=$phase"
fi

# Case 2: improve_iteration=2, P1+P2>0 → TRIAGE/triage 再遷移
cat > "$tmpdir/sprint/state.json" <<'EOF'
{"phase":"COMPLETE","sub_phase":"improve","gate_approvals":{},"triage":{"P1":1,"P2":0},"improve_iteration":2,"subagent_health":{}}
EOF
(cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null)
phase=$(jq -r '.phase' "$tmpdir/sprint/state.json")
sub=$(jq -r '.sub_phase' "$tmpdir/sprint/state.json")
if [ "$phase" = "TRIAGE" ] && [ "$sub" = "triage" ]; then
  pass=$((pass+1)); echo "  PASS: improve_iteration=2 → TRIAGE/triage"
else
  fail=$((fail+1)); echo "  FAIL: got $phase/$sub"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
