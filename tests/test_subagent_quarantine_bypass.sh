#!/usr/bin/env bash
# tests/test_subagent_quarantine_bypass.sh — T-B.9
#
# 目的:
#   scripts/phase-advance-eval.sh が state.json.subagent_health[<agent>].quarantine_until を見て、
#   quarantine 中なら bypass 経路の指示を出力すること（bypass 不可なら ESCALATION 遷移）。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EVAL="$REPO_ROOT/scripts/phase-advance-eval.sh"

[ -x "$EVAL" ] || { echo "FAIL: eval not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

fail=0
pass=0

now_ms=$(($(date +%s%N) / 1000000))
future_ms=$((now_ms + 600000))  # 10 分後

# Case 1: investigator quarantine 中 + TRIAGE / FINDINGS あり・BRIEF なし
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint"
cat > "$tmpdir/sprint/state.json" <<EOF
{
  "phase": "TRIAGE",
  "sub_phase": "triage",
  "subagent_health": { "investigator": { "quarantine_until": ${future_ms} } },
  "gate_approvals": {},
  "triage_artifacts": { "p1_count": 1, "p2_count": 0 }
}
EOF
: > "$tmpdir/sprint/IMPROVE_FINDINGS.md"

out=$(cd "$tmpdir" && bash "$EVAL" 2>&1)
if echo "$out" | grep -q "FINDINGS をそのまま BRIEF"; then
  pass=$((pass+1)); echo "  PASS: investigator bypass path emitted"
else
  fail=$((fail+1)); echo "  FAIL: investigator bypass not emitted, got: $out"
fi

# Case 2: investigator quarantine なし → 通常経路
cat > "$tmpdir/sprint/state.json" <<EOF
{
  "phase": "TRIAGE",
  "sub_phase": "triage",
  "subagent_health": {},
  "gate_approvals": {},
  "triage_artifacts": { "p1_count": 1, "p2_count": 0 }
}
EOF

out=$(cd "$tmpdir" && bash "$EVAL" 2>&1)
if echo "$out" | grep -q "investigator サブエージェントを起動"; then
  pass=$((pass+1)); echo "  PASS: normal path emitted when not quarantined"
else
  fail=$((fail+1)); echo "  FAIL: normal path not emitted, got: $out"
fi

# Case 3: clarifier quarantine 中 → ESCALATION 指示
cat > "$tmpdir/sprint/state.json" <<EOF
{
  "phase": "CLARIFY",
  "sub_phase": "implement",
  "subagent_health": { "clarifier": { "quarantine_until": ${future_ms} } },
  "gate_approvals": {}
}
EOF

out=$(cd "$tmpdir" && bash "$EVAL" 2>&1)
if echo "$out" | grep -qE "ESCALATION|bypass 不可"; then
  pass=$((pass+1)); echo "  PASS: clarifier quarantine -> ESCALATION"
else
  fail=$((fail+1)); echo "  FAIL: clarifier ESCALATION path not emitted, got: $out"
fi

# Case 4: quarantine_until 過去 → 通常経路
cat > "$tmpdir/sprint/state.json" <<EOF
{
  "phase": "TRIAGE",
  "sub_phase": "triage",
  "subagent_health": { "investigator": { "quarantine_until": $((now_ms - 60000)) } },
  "gate_approvals": {},
  "triage_artifacts": { "p1_count": 1, "p2_count": 0 }
}
EOF

out=$(cd "$tmpdir" && bash "$EVAL" 2>&1)
if echo "$out" | grep -q "investigator サブエージェントを起動"; then
  pass=$((pass+1)); echo "  PASS: expired quarantine treated as normal"
else
  fail=$((fail+1)); echo "  FAIL: expired quarantine not handled, got: $out"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
