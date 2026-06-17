#!/usr/bin/env bash
# tests/test_verify_unresolved_to_triage.sh
#
# 提案 X の検証: VERIFY 失敗時の遷移経路 (EXECUTE 差戻し / TRIAGE 強制合流)。
#
# 設計意図:
#   実装 EXECUTE ⇄ VERIFY のミニループ (設計書 §6.1 / §6.6) を phase 遷移で表現し、
#   ループ上限到達時には TRIAGE/bug-hunter に強制合流させて「実装中の取りこぼし」を
#   発掘経路に確実に乗せる。
#
# 検証範囲:
#   1. VERIFY/implement + all_pass=false + max_failure_count<5  → EXECUTE/implement
#   2. VERIFY/implement + all_pass=false + max_failure_count>=5 → TRIAGE/triage
#   3. VERIFY/improve   + all_pass=false + max_failure_count<5  → EXECUTE/improve
#   4. VERIFY/improve   + all_pass=false + max_failure_count>=5 → TRIAGE/triage
#   5. VERIFY/implement + evaluator_scores 未設定               → 停留 (既存挙動)
#   6. apply.sh が TRIAGE 突入時に entry_reason=verify_unresolved を記録
#   7. apply.sh が TRIAGE 突入時に improve_iteration を +1
#   8. apply.sh: 通常完走経由 (COMPLETE/implement → TRIAGE) は entry_reason=complete_implement
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

PASS=0
FAIL=0

setup_workdir() {
  local d="$1"
  mkdir -p "$d/sprint/tasks" "$d/scripts"
  for s in phase-advance-apply.sh phase-advance-eval.sh \
           phase-advance-eval-next-phase.sh phase-advance-eval-next-sub.sh \
           plan-waves.sh; do
    cp "$REPO_ROOT/scripts/$s" "$d/scripts/$s"
    chmod +x "$d/scripts/$s"
  done
}

expect() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected=$expected got=$actual)"
  fi
}

write_state() {
  local dir="$1" json="$2"
  echo "$json" > "$dir/sprint/state.json"
}

write_task_status() {
  local dir="$1" id="$2" failure_count="$3"
  cat > "$dir/sprint/tasks/${id}.status.json" <<EOF
{"status":"COMPLETE","tdd_phase":"GREEN","failure_count":${failure_count}}
EOF
}

next_phase() { (cd "$1" && bash ./scripts/phase-advance-eval-next-phase.sh 2>/dev/null) || true; }
next_sub()   { (cd "$1" && bash ./scripts/phase-advance-eval-next-sub.sh   2>/dev/null) || true; }
apply()      { (cd "$1" && bash ./scripts/phase-advance-apply.sh           2>/dev/null) || true; }

echo "=== test_verify_unresolved_to_triage.sh (提案 X) ==="

# ---------- ケース 1: VERIFY/implement 失敗 + max_failure_count<5 → EXECUTE ----------
echo "--- C1: VERIFY/implement 失敗 + failure_count=2 → EXECUTE/implement ---"
W=$(mktemp -d); setup_workdir "$W"
write_state "$W" '{
  "phase":"VERIFY","sub_phase":"implement","v2_active":true,
  "evaluator_scores":["FAIL","PASS"],
  "tasks":{"task-001":{"status":"COMPLETE","depends_on":[],"touches":["src/foo.ts"]}},
  "resume_hint":{"in_flight":[]},
  "triage":{"P1":0,"P2":0},"triage_artifacts":{"p1_count":0,"p2_count":0},
  "gate_approvals":{},"subagent_health":{},"improve_iteration":0,
  "contract":{"agreed":true},"integrate":{"pr_url":""}
}'
write_task_status "$W" "task-001" 2
expect "C1 next_phase=EXECUTE" "EXECUTE" "$(next_phase "$W")"
expect "C1 next_sub=implement"  "implement" "$(next_sub "$W")"
rm -rf "$W"

# ---------- ケース 2: VERIFY/implement 失敗 + max_failure_count>=5 → TRIAGE ----------
echo "--- C2: VERIFY/implement 失敗 + failure_count=5 → TRIAGE/triage ---"
W=$(mktemp -d); setup_workdir "$W"
write_state "$W" '{
  "phase":"VERIFY","sub_phase":"implement","v2_active":true,
  "evaluator_scores":["FAIL","PASS"],
  "tasks":{"task-001":{"status":"COMPLETE"}},
  "resume_hint":{"in_flight":[]},
  "triage":{"P1":0,"P2":0},"triage_artifacts":{"p1_count":0,"p2_count":0},
  "gate_approvals":{},"subagent_health":{},"improve_iteration":0,
  "contract":{"agreed":true},"integrate":{"pr_url":""}
}'
write_task_status "$W" "task-001" 5
expect "C2 next_phase=TRIAGE" "TRIAGE" "$(next_phase "$W")"
expect "C2 next_sub=triage"   "triage"  "$(next_sub "$W")"
rm -rf "$W"

# ---------- ケース 3: VERIFY/improve 失敗 + max_failure_count<5 → EXECUTE/improve ----------
echo "--- C3: VERIFY/improve 失敗 + failure_count=1 → EXECUTE/improve ---"
W=$(mktemp -d); setup_workdir "$W"
write_state "$W" '{
  "phase":"VERIFY","sub_phase":"improve","v2_active":true,
  "evaluator_scores":["FAIL"],
  "tasks":{"I-001":{"status":"COMPLETE"}},
  "resume_hint":{"in_flight":[]},
  "triage":{"P1":1,"P2":0},"triage_artifacts":{"p1_count":1,"p2_count":0},
  "gate_approvals":{"TRIAGE_TO_IMPROVE":true},"subagent_health":{},"improve_iteration":1,
  "contract":{"agreed":true},"integrate":{"pr_url":""}
}'
write_task_status "$W" "I-001" 1
expect "C3 next_phase=EXECUTE" "EXECUTE" "$(next_phase "$W")"
expect "C3 next_sub=improve"   "improve" "$(next_sub "$W")"
rm -rf "$W"

# ---------- ケース 4: VERIFY/improve 失敗 + max_failure_count>=5 → TRIAGE ----------
echo "--- C4: VERIFY/improve 失敗 + failure_count=7 → TRIAGE/triage (強制合流) ---"
W=$(mktemp -d); setup_workdir "$W"
write_state "$W" '{
  "phase":"VERIFY","sub_phase":"improve","v2_active":true,
  "evaluator_scores":["FAIL"],
  "tasks":{"I-001":{"status":"COMPLETE"}},
  "resume_hint":{"in_flight":[]},
  "triage":{"P1":1,"P2":0},"triage_artifacts":{"p1_count":1,"p2_count":0},
  "gate_approvals":{"TRIAGE_TO_IMPROVE":true},"subagent_health":{},"improve_iteration":1,
  "contract":{"agreed":true},"integrate":{"pr_url":""}
}'
write_task_status "$W" "I-001" 7
expect "C4 next_phase=TRIAGE" "TRIAGE" "$(next_phase "$W")"
expect "C4 next_sub=triage"   "triage"  "$(next_sub "$W")"
rm -rf "$W"

# ---------- ケース 5: VERIFY/implement + evaluator_scores 未設定 → 停留 ----------
echo "--- C5: VERIFY/implement + evaluator_scores=[] → 停留 (既存挙動) ---"
W=$(mktemp -d); setup_workdir "$W"
write_state "$W" '{
  "phase":"VERIFY","sub_phase":"implement","v2_active":true,
  "evaluator_scores":[],
  "tasks":{"task-001":{"status":"COMPLETE"}},
  "resume_hint":{"in_flight":[]},
  "triage":{"P1":0,"P2":0},"triage_artifacts":{"p1_count":0,"p2_count":0},
  "gate_approvals":{},"subagent_health":{},"improve_iteration":0,
  "contract":{"agreed":true},"integrate":{"pr_url":""}
}'
write_task_status "$W" "task-001" 0
expect "C5 next_phase 空 (停留)" "" "$(next_phase "$W")"
rm -rf "$W"

# ---------- ケース 6: apply.sh が TRIAGE 突入時に entry_reason=verify_unresolved を記録 ----------
echo "--- C6: VERIFY → TRIAGE 遷移時 entry_reason=verify_unresolved ---"
W=$(mktemp -d); setup_workdir "$W"
write_state "$W" '{
  "phase":"VERIFY","sub_phase":"implement","v2_active":true,
  "evaluator_scores":["FAIL"],
  "tasks":{"task-001":{"status":"COMPLETE"}},
  "resume_hint":{"in_flight":[]},
  "triage":{"P1":0,"P2":0},"triage_artifacts":{"p1_count":0,"p2_count":0},
  "gate_approvals":{},"subagent_health":{},"improve_iteration":0,
  "contract":{"agreed":true},"integrate":{"pr_url":""}
}'
write_task_status "$W" "task-001" 5
apply "$W" > /dev/null
expect "C6 phase=TRIAGE"      "TRIAGE"            "$(jq -r '.phase' "$W/sprint/state.json")"
expect "C6 sub_phase=triage"  "triage"            "$(jq -r '.sub_phase' "$W/sprint/state.json")"
expect "C6 entry_reason"      "verify_unresolved" "$(jq -r '.triage_artifacts.entry_reason' "$W/sprint/state.json")"
expect "C6 improve_iteration=1" "1"               "$(jq -r '.improve_iteration' "$W/sprint/state.json")"
rm -rf "$W"

# ---------- ケース 7: COMPLETE/implement → TRIAGE 通常完走経路 entry_reason=complete_implement ----------
echo "--- C7: COMPLETE/implement → TRIAGE 遷移時 entry_reason=complete_implement ---"
W=$(mktemp -d); setup_workdir "$W"
write_state "$W" '{
  "phase":"COMPLETE","sub_phase":"implement","v2_active":true,
  "evaluator_scores":["PASS"],
  "tasks":{"task-001":{"status":"COMPLETE"}},
  "resume_hint":{"in_flight":[]},
  "triage":{"P1":0,"P2":0},"triage_artifacts":{"p1_count":0,"p2_count":0},
  "gate_approvals":{},"subagent_health":{},"improve_iteration":0,
  "contract":{"agreed":true},"integrate":{"pr_url":"https://example.com/pr/1"}
}'
write_task_status "$W" "task-001" 0
apply "$W" > /dev/null
expect "C7 phase=TRIAGE"     "TRIAGE"             "$(jq -r '.phase' "$W/sprint/state.json")"
expect "C7 sub_phase=triage" "triage"             "$(jq -r '.sub_phase' "$W/sprint/state.json")"
expect "C7 entry_reason"     "complete_implement" "$(jq -r '.triage_artifacts.entry_reason' "$W/sprint/state.json")"
rm -rf "$W"

# ---------- ケース 8: COMPLETE/improve → TRIAGE 再合流経路 entry_reason=complete_improve_loop ----------
echo "--- C8: COMPLETE/improve → TRIAGE 遷移時 entry_reason=complete_improve_loop ---"
W=$(mktemp -d); setup_workdir "$W"
write_state "$W" '{
  "phase":"COMPLETE","sub_phase":"improve","v2_active":true,
  "evaluator_scores":["PASS"],
  "tasks":{"I-001":{"status":"COMPLETE"}},
  "resume_hint":{"in_flight":[]},
  "triage":{"P1":1,"P2":0},"triage_artifacts":{"p1_count":1,"p2_count":0},
  "gate_approvals":{"TRIAGE_TO_IMPROVE":true},"subagent_health":{},"improve_iteration":1,
  "contract":{"agreed":true},"integrate":{"pr_url":"https://example.com/pr/2"}
}'
write_task_status "$W" "I-001" 0
apply "$W" > /dev/null
expect "C8 phase=TRIAGE"       "TRIAGE"                 "$(jq -r '.phase' "$W/sprint/state.json")"
expect "C8 sub_phase=triage"   "triage"                 "$(jq -r '.sub_phase' "$W/sprint/state.json")"
expect "C8 entry_reason"       "complete_improve_loop"  "$(jq -r '.triage_artifacts.entry_reason' "$W/sprint/state.json")"
expect "C8 improve_iteration=2" "2"                     "$(jq -r '.improve_iteration' "$W/sprint/state.json")"
rm -rf "$W"

echo ""
echo "Total: pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
