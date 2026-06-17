#!/usr/bin/env bash
# sub_phase の遷移を検証するテスト (T-C.7)
#
# 注意:
#   - apply.sh は cwd 相対で scripts/phase-advance-eval-next-{phase,sub}.sh を呼び出すため、
#     tmpdir に scripts/ 配下を複製してから cd して実行する。
#   - state.json のスキーマは「triage.P1 / triage.P2」（eval-next-phase.sh が参照）。
#     triage_artifacts.{p1_count,p2_count} はゲート評価用（eval.sh）の別フィールド。
#   - TRIAGE→CLARIFY/COMPLETE 遷移は sprint/BRIEF.md の存在も判定条件。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
APPLY="$REPO_ROOT/scripts/phase-advance-apply.sh"
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

# Case 1: COMPLETE/implement → TRIAGE/triage
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
echo '{"phase":"COMPLETE","sub_phase":"implement","gate_approvals":{},"triage":{"P1":0,"P2":0},"improve_iteration":0}' > "$tmpdir/sprint/state.json"
(cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null)
phase=$(jq -r '.phase' "$tmpdir/sprint/state.json")
sub=$(jq -r '.sub_phase' "$tmpdir/sprint/state.json")
if [ "$phase" = "TRIAGE" ] && [ "$sub" = "triage" ]; then
  pass=$((pass+1)); echo "  PASS: COMPLETE/implement → TRIAGE/triage"
else
  fail=$((fail+1)); echo "  FAIL: got $phase/$sub"
fi
rm -rf "$tmpdir"

# Case 2: TRIAGE/triage → CLARIFY/improve (gate=true, P1+P2>0, BRIEF.md 存在)
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
echo '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{"TRIAGE_TO_IMPROVE":true},"triage":{"P1":1,"P2":0},"improve_iteration":0}' > "$tmpdir/sprint/state.json"
: > "$tmpdir/sprint/BRIEF.md"
(cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null)
phase=$(jq -r '.phase' "$tmpdir/sprint/state.json")
sub=$(jq -r '.sub_phase' "$tmpdir/sprint/state.json")
if [ "$phase" = "CLARIFY" ] && [ "$sub" = "improve" ]; then
  pass=$((pass+1)); echo "  PASS: TRIAGE/triage → CLARIFY/improve"
else
  fail=$((fail+1)); echo "  FAIL: got $phase/$sub"
fi
rm -rf "$tmpdir"

# Case 3: COMPLETE/improve → COMPLETE/implement (P1+P2=0)
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
echo '{"phase":"COMPLETE","sub_phase":"improve","gate_approvals":{},"triage":{"P1":0,"P2":0},"improve_iteration":1}' > "$tmpdir/sprint/state.json"
(cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null)
phase=$(jq -r '.phase' "$tmpdir/sprint/state.json")
sub=$(jq -r '.sub_phase' "$tmpdir/sprint/state.json")
if [ "$phase" = "COMPLETE" ] && [ "$sub" = "implement" ]; then
  pass=$((pass+1)); echo "  PASS: COMPLETE/improve (P1+P2=0) → COMPLETE/implement"
else
  fail=$((fail+1)); echo "  FAIL: got $phase/$sub"
fi
rm -rf "$tmpdir"

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
