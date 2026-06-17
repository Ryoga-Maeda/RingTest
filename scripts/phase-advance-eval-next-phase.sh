#!/usr/bin/env bash
# 遷移表に基づき、次の phase を stdout に出力する純関数。
# 遷移なしの場合は空文字を出力。
# 引数なし・環境変数なし。state.json を読むだけで副作用なし。
set -euo pipefail

STATE=sprint/state.json
[ -f "$STATE" ] || { echo ""; exit 0; }

cur_phase=$(jq -r '.phase // ""' "$STATE")
cur_sub=$(jq -r '.sub_phase // ""' "$STATE")
improve_iter=$(jq -r '.improve_iteration // 0' "$STATE")

# ゲート承認
gate_clarify_to_design=$(jq -r '.gate_approvals.CLARIFY_TO_DESIGN // false' "$STATE")
gate_triage_to_improve=$(jq -r '.gate_approvals.TRIAGE_TO_IMPROVE // false' "$STATE")
gate_improve_clarify_to_design=$(jq -r '.gate_approvals.IMPROVE_CLARIFY_TO_DESIGN // false' "$STATE")

# contract / DAG
contract_agreed=$(jq -r '.contract.agreed // false' "$STATE")

# evaluator scores: 全要素 PASS かつ要素数>=1 なら all_pass=true
all_pass=$(jq -r '
  if (.evaluator_scores // null) == null then "undef"
  elif (.evaluator_scores | length) == 0 then "undef"
  elif (.evaluator_scores | all(. == "PASS")) then "true"
  else "false" end
' "$STATE")

# integrate.pr_url
pr_url=$(jq -r '.integrate.pr_url // ""' "$STATE")

# BRIEF / P1+P2
brief_exists="false"
if [ -f sprint/BRIEF.md ]; then brief_exists="true"; fi
p1p2=$(jq -r '((.triage.P1 // 0) + (.triage.P2 // 0))' "$STATE" 2>/dev/null || echo 0)

# 全タスク COMPLETE 判定 + 最大 failure_count 集計 (sprint/tasks/*.status.json)
# max_failure_count は VERIFY 失敗時の差戻し上限判定に用いる（5 回到達で TRIAGE へ強制合流）。
tasks_all_complete="undef"
max_failure_count=0
if compgen -G "sprint/tasks/*.status.json" > /dev/null; then
  total=0
  done_n=0
  for f in sprint/tasks/*.status.json; do
    total=$((total + 1))
    s=$(jq -r '.status // ""' "$f" 2>/dev/null || echo "")
    if [ "$s" = "COMPLETE" ]; then done_n=$((done_n + 1)); fi
    fc=$(jq -r '.failure_count // 0' "$f" 2>/dev/null || echo 0)
    if [ "$fc" -gt "$max_failure_count" ]; then max_failure_count="$fc"; fi
  done
  if [ "$total" -gt 0 ] && [ "$total" -eq "$done_n" ]; then
    tasks_all_complete="true"
  else
    tasks_all_complete="false"
  fi
fi
# VERIFY 差戻し上限（実装フェーズ EXECUTE ⇄ VERIFY ミニループ最大回数）。
# 設計書 §6.1 / §6.6 の「実装 EXECUTE⇄VERIFY 5回」に合わせる。
VERIFY_FAILURE_LIMIT=${VERIFY_FAILURE_LIMIT:-5}

# in_flight 空 判定
in_flight_empty=$(jq -r '((.resume_hint.in_flight // []) | length) == 0' "$STATE")

# plan-waves.sh OK (DAG 循環なし)
plan_waves_ok="false"
if [ "$contract_agreed" = "true" ]; then
  if scripts/plan-waves.sh > /dev/null 2>&1; then
    plan_waves_ok="true"
  fi
fi

# PRODUCT.md / SPRINT.md / IMPROVE.md 存在判定
product_exists="false"; [ -f sprint/PRODUCT.md ] && product_exists="true"
sprint_exists="false"; [ -f sprint/SPRINT.md ] && sprint_exists="true"
improve_exists="false"; [ -f sprint/IMPROVE.md ] && improve_exists="true"

next=""

case "$cur_phase/$cur_sub" in
  "CLARIFY/implement")
    if [ "$product_exists" = "true" ] && [ "$gate_clarify_to_design" = "true" ]; then
      next="DESIGN"
    fi
    ;;
  "DESIGN/"*)
    if [ "$sprint_exists" = "true" ]; then
      next="PLAN"
    fi
    ;;
  "PLAN/"*)
    if [ "$contract_agreed" = "true" ] && [ "$plan_waves_ok" = "true" ]; then
      next="EXECUTE"
    fi
    ;;
  "EXECUTE/"*)
    if [ "$in_flight_empty" = "true" ] && [ "$tasks_all_complete" = "true" ]; then
      next="VERIFY"
    fi
    ;;
  "VERIFY/"*)
    if [ "$all_pass" = "true" ]; then
      next="INTEGRATE"
    elif [ "$max_failure_count" -ge "$VERIFY_FAILURE_LIMIT" ]; then
      # 設計書 §6.1 / §6.6 のミニループ上限到達。TRIAGE/bug-hunter に強制合流させ、
      # 「実装中の取りこぼし」を取りこぼさないようにする (提案 X)。
      next="TRIAGE"
    elif [ "$all_pass" = "false" ]; then
      # FAIL 残存かつ上限未達 → EXECUTE 差戻し（verifier 責務定義の
      # 「failure_count を +1 にして EXECUTE 再開」を phase 遷移として表現）。
      next="EXECUTE"
    fi
    ;;
  "INTEGRATE/"*)
    if [ -n "$pr_url" ]; then
      next="COMPLETE"
    fi
    ;;
  "COMPLETE/implement")
    next="TRIAGE"
    ;;
  "TRIAGE/triage")
    if [ "$brief_exists" = "true" ] && [ "$p1p2" -eq 0 ]; then
      next="COMPLETE"
    elif [ "$brief_exists" = "true" ] && [ "$p1p2" -gt 0 ] && [ "$gate_triage_to_improve" = "true" ]; then
      next="CLARIFY"
    fi
    ;;
  "CLARIFY/improve")
    if [ "$improve_exists" = "true" ] && [ "$gate_improve_clarify_to_design" = "true" ]; then
      next="DESIGN"
    fi
    ;;
  "COMPLETE/improve")
    if [ "$p1p2" -gt 0 ] && [ "$improve_iter" -lt 3 ]; then
      next="TRIAGE"
    elif [ "$p1p2" -gt 0 ] && [ "$improve_iter" -ge 3 ]; then
      next="ESCALATION"
    elif [ "$p1p2" -eq 0 ]; then
      next="COMPLETE"
    fi
    ;;
esac

# 冪等性: 既に同じ phase 値の場合、sub_phase 変更を伴うものだけ残し、それ以外は空に
# ただし sub_phase 切替を伴うケース (COMPLETE/implement -> TRIAGE/triage 等) は next を保持
if [ -n "$next" ] && [ "$next" = "$cur_phase" ]; then
  # COMPLETE/improve -> COMPLETE/implement は sub_phase が変わるので next を維持する必要がある
  # よってここでは何もしない（next を保持）
  :
fi

echo "$next"
