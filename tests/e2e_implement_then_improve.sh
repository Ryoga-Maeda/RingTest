#!/usr/bin/env bash
# tests/e2e_implement_then_improve.sh — T-C.13
#
# 実装フェーズ → TRIAGE → 改善フェーズ → スプリント完了までの全フェーズ遷移を
# モック駆動で通しで検証する E2E。
#
# 検証範囲:
#   - phase-advance-apply.sh + phase-advance-eval-next-{phase,sub}.sh の遷移チェーン
#   - phase-advance-eval.sh が各フェーズで生成する「次の一手」指示文
#   - bug-hunter (FINDINGS 生成) / investigator (BRIEF 生成) のモック注入
#   - ゲート (CLARIFY_TO_DESIGN / TRIAGE_TO_IMPROVE / IMPROVE_CLARIFY_TO_DESIGN) の自動承認
#   - improve_iteration インクリメント / P1+P2=0 で改善ループ脱出
#
# モック方針:
#   - サブエージェント本体は起動しない。代わりにテストが直接 PRODUCT.md / SPRINT.md /
#     IMPROVE_FINDINGS.md / IMPROVE_BRIEF.md / IMPROVE.md / sprint/tasks/*.status.json を投入し、
#     state.json の必要フィールド (contract.agreed / evaluator_scores / integrate.pr_url /
#     triage.P1,P2 / triage_artifacts.* / gate_approvals.*) を jq で更新する。
#   - phase-advance-apply.sh を毎ターン呼び、phase/sub_phase の変化と phase_log.jsonl の追記を assert する。
#   - phase-advance-eval.sh を呼び、現フェーズで期待する指示エージェント名が指示文に含まれることを assert する。
#
# 注: phase-advance-eval-next-phase.sh は triage.P1 / triage.P2 を見るが、
#     phase-advance-eval.sh の TRIAGE 分岐は triage_artifacts.p1_count / p2_count を見る。
#     E2E では両方を同期更新する。
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

expect_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $desc (needle='$needle' not found in: $haystack)"
  fi
}

state() { jq -r "$1" "$WORK/sprint/state.json"; }

state_update() {
  local expr="$1"
  local tmp
  tmp=$(mktemp)
  jq "$expr" "$WORK/sprint/state.json" > "$tmp" && mv "$tmp" "$WORK/sprint/state.json"
}

apply() { (cd "$WORK" && bash ./scripts/phase-advance-apply.sh 2>/dev/null) || true; }
eval_hint() { (cd "$WORK" && bash ./scripts/phase-advance-eval.sh 2>/dev/null) || true; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
setup_workdir "$WORK"

echo "=== e2e_implement_then_improve.sh (T-C.13) ==="

# ---------- 初期 state ----------
cat > "$WORK/sprint/state.json" <<'EOF'
{
  "phase": "CLARIFY",
  "sub_phase": "implement",
  "v2_active": true,
  "contract": {"agreed": false, "iteration": 0, "max_iterations": 15},
  "gate_approvals": {},
  "tasks": {},
  "resume_hint": {"in_flight": []},
  "evaluator_scores": [],
  "integrate": {"pr_url": ""},
  "triage": {"P1": 0, "P2": 0},
  "triage_artifacts": {"p1_count": 0, "p2_count": 0},
  "subagent_health": {},
  "improve_iteration": 0
}
EOF

echo "--- ステップ1: CLARIFY/implement で clarifier 起動指示 ---"
out=$(eval_hint)
expect_contains "[CLARIFY] clarifier 起動指示" "clarifier" "$out"

echo "--- ステップ2: PRODUCT.md 投入 + CLARIFY_TO_DESIGN ゲート → DESIGN/implement へ ---"
: > "$WORK/sprint/PRODUCT.md"
state_update '.gate_approvals.CLARIFY_TO_DESIGN = true'
apply
expect "phase=DESIGN" "DESIGN" "$(state '.phase')"
expect "sub_phase=implement" "implement" "$(state '.sub_phase')"

echo "--- ステップ3: DESIGN で designer 起動指示 ---"
out=$(eval_hint)
expect_contains "[DESIGN] designer 起動指示" "designer" "$out"

echo "--- ステップ4: SPRINT.md 投入 → PLAN へ ---"
: > "$WORK/sprint/SPRINT.md"
apply
expect "phase=PLAN" "PLAN" "$(state '.phase')"

echo "--- ステップ5: PLAN で decomposer 起動指示 (契約未合意時) ---"
out=$(eval_hint)
expect_contains "[PLAN] decomposer 起動指示" "decomposer" "$out"

echo "--- ステップ6: contract.agreed=true (空 tasks で DAG 循環なし) → EXECUTE へ ---"
state_update '.contract.agreed = true'
apply
expect "phase=EXECUTE" "EXECUTE" "$(state '.phase')"

echo "--- ステップ7: EXECUTE で executor 起動指示 ---"
out=$(eval_hint)
expect_contains "[EXECUTE] executor 起動指示" "executor" "$out"

echo "--- ステップ8: 1 タスク完走 (status.json COMPLETE) + in_flight 空 → VERIFY へ ---"
state_update '.tasks["task-001"] = {"status":"COMPLETE","depends_on":[],"touches":["src/foo.ts"]} | .resume_hint.in_flight = []'
cat > "$WORK/sprint/tasks/task-001.status.json" <<'EOF'
{"status":"COMPLETE","tdd_phase":"GREEN","failure_count":0}
EOF
apply
expect "phase=VERIFY" "VERIFY" "$(state '.phase')"

echo "--- ステップ9: VERIFY で verifier 起動指示 ---"
out=$(eval_hint)
expect_contains "[VERIFY] verifier 起動指示" "verifier" "$out"

echo "--- ステップ10: evaluator_scores 全 PASS → INTEGRATE へ ---"
state_update '.evaluator_scores = ["PASS","PASS"]'
apply
expect "phase=INTEGRATE" "INTEGRATE" "$(state '.phase')"

echo "--- ステップ11: INTEGRATE で integrator 起動指示 ---"
out=$(eval_hint)
expect_contains "[INTEGRATE] integrator 起動指示" "integrator" "$out"

echo "--- ステップ12: integrate.pr_url 設定 → COMPLETE/implement へ ---"
state_update '.integrate.pr_url = "https://github.com/example/repo/pull/1"'
apply
expect "phase=COMPLETE (implement 完走)" "COMPLETE" "$(state '.phase')"
expect "sub_phase=implement (TRIAGE 入る前)" "implement" "$(state '.sub_phase')"

echo "--- ステップ13: COMPLETE/implement で bug-hunter 起動指示 + TRIAGE/triage へ自動遷移 ---"
out=$(eval_hint)
expect_contains "[COMPLETE/implement] bug-hunter 起動指示" "bug-hunter" "$out"
apply
expect "phase=TRIAGE" "TRIAGE" "$(state '.phase')"
expect "sub_phase=triage" "triage" "$(state '.sub_phase')"
expect "improve_iteration=1 (triage 切替時 +1)" "1" "$(state '.improve_iteration')"

echo "--- ステップ14: TRIAGE で FINDINGS 未生成 → bug-hunter 起動指示 ---"
out=$(eval_hint)
expect_contains "[TRIAGE] bug-hunter (FINDINGS 未生成)" "bug-hunter" "$out"

echo "--- ステップ15: FINDINGS 投入 → investigator 起動指示 ---"
: > "$WORK/sprint/IMPROVE_FINDINGS.md"
out=$(eval_hint)
expect_contains "[TRIAGE] investigator (BRIEF 未生成)" "investigator" "$out"

echo "--- ステップ16: BRIEF 投入 + P1+P2 > 0 + ゲート未承認 → AskUserQuestion ---"
: > "$WORK/sprint/IMPROVE_BRIEF.md"
: > "$WORK/sprint/BRIEF.md"  # next-phase 判定用
state_update '.triage_artifacts.p1_count = 1 | .triage.P1 = 1'
out=$(eval_hint)
expect_contains "[TRIAGE] gate 未承認 → AskUserQuestion" "AskUserQuestion" "$out"

echo "--- ステップ17: TRIAGE_TO_IMPROVE 承認 → CLARIFY/improve へ ---"
state_update '.gate_approvals.TRIAGE_TO_IMPROVE = true'
apply
expect "phase=CLARIFY" "CLARIFY" "$(state '.phase')"
expect "sub_phase=improve" "improve" "$(state '.sub_phase')"

echo "--- ステップ18: CLARIFY/improve で clarifier (IMPROVE_BRIEF.md パラメータ) 起動指示 ---"
out=$(eval_hint)
expect_contains "[CLARIFY/improve] clarifier 起動指示" "clarifier" "$out"
expect_contains "[CLARIFY/improve] パラメータに IMPROVE_BRIEF.md" "IMPROVE_BRIEF.md" "$out"

echo "--- ステップ19: IMPROVE.md 投入 + IMPROVE_CLARIFY_TO_DESIGN 承認 → DESIGN/improve へ ---"
: > "$WORK/sprint/IMPROVE.md"
state_update '.gate_approvals.IMPROVE_CLARIFY_TO_DESIGN = true'
apply
expect "phase=DESIGN" "DESIGN" "$(state '.phase')"
expect "sub_phase=improve (維持)" "improve" "$(state '.sub_phase')"

echo "--- ステップ20: 改善フェーズで PLAN → EXECUTE → VERIFY → INTEGRATE → COMPLETE/improve ---"
apply  # DESIGN → PLAN (SPRINT.md 既存)
expect "phase=PLAN" "PLAN" "$(state '.phase')"
# 改善フェーズ用に I-001 を投入 (tasks_all_complete 判定のため status.json を生成)
state_update '.tasks = {"I-001": {"status":"COMPLETE","depends_on":[],"touches":["src/bar.ts"]}} | .resume_hint.in_flight = [] | .evaluator_scores = ["PASS"] | .integrate.pr_url = "https://github.com/example/repo/pull/2"'
rm -f "$WORK/sprint/tasks/task-001.status.json"
cat > "$WORK/sprint/tasks/I-001.status.json" <<'EOF'
{"status":"COMPLETE","tdd_phase":"GREEN","failure_count":0}
EOF
apply  # PLAN → EXECUTE (contract.agreed 既に true)
expect "phase=EXECUTE (改善)" "EXECUTE" "$(state '.phase')"
apply  # EXECUTE → VERIFY (タスク空)
expect "phase=VERIFY (改善)" "VERIFY" "$(state '.phase')"
apply  # VERIFY → INTEGRATE (evaluator_scores 全 PASS)
expect "phase=INTEGRATE (改善)" "INTEGRATE" "$(state '.phase')"
apply  # INTEGRATE → COMPLETE/improve (pr_url 設定済み)
expect "phase=COMPLETE" "COMPLETE" "$(state '.phase')"
expect "sub_phase=improve" "improve" "$(state '.sub_phase')"

echo "--- ステップ21: 改善完了 (P1+P2=0) → COMPLETE/implement 復帰 ---"
state_update '.triage.P1 = 0 | .triage.P2 = 0 | .triage_artifacts.p1_count = 0 | .triage_artifacts.p2_count = 0'
apply
expect "phase=COMPLETE (改善完了)" "COMPLETE" "$(state '.phase')"
expect "sub_phase=implement (復帰)" "implement" "$(state '.sub_phase')"

echo "--- ステップ22: COMPLETE/implement で completer 起動指示 (TRIAGE 一巡後の再 COMPLETE) ---"
# TRIAGE_TO_IMPROVE は既に true なので、COMPLETE/implement → TRIAGE → 即 COMPLETE/implement に戻るループを避けるため
# triage_artifacts/triage を 0 にしてある。bug-hunter 指示が出るが、これは設計通り（再度 TRIAGE に入る）。
out=$(eval_hint)
expect_contains "[COMPLETE/implement] bug-hunter 起動指示 (再 TRIAGE 入口)" "bug-hunter" "$out"

echo "--- ステップ23: phase_log.jsonl に複数遷移が記録されている ---"
log_lines=$(wc -l < "$WORK/sprint/phase_log.jsonl")
[ "$log_lines" -ge 8 ] && { PASS=$((PASS+1)); echo "  PASS: phase_log.jsonl に $log_lines 行 (>=8)"; } \
                      || { FAIL=$((FAIL+1)); echo "  FAIL: phase_log.jsonl が $log_lines 行のみ"; }

echo ""
echo "Total: pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
