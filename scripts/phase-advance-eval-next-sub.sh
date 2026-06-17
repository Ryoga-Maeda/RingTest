#!/usr/bin/env bash
# 遷移表に基づき、次の sub_phase を stdout に出力する純関数。
# 遷移なしの場合は空文字。
# 引数なし・環境変数なし。
set -euo pipefail

STATE=sprint/state.json
[ -f "$STATE" ] || { echo ""; exit 0; }

cur_phase=$(jq -r '.phase // ""' "$STATE")
cur_sub=$(jq -r '.sub_phase // ""' "$STATE")

# next phase を eval スクリプトから取得し、表に基づき次の sub を決定する
next_phase=$(scripts/phase-advance-eval-next-phase.sh)
if [ -z "$next_phase" ]; then
  echo ""
  exit 0
fi

# 表に基づく sub_phase 決定:
#   CLARIFY(implement) -> DESIGN/implement
#   DESIGN/*           -> PLAN/(維持)
#   PLAN/*             -> EXECUTE/(維持)
#   EXECUTE/*          -> VERIFY/(維持)
#   VERIFY/*           -> INTEGRATE/(維持)
#   VERIFY/implement(fail,iter<limit)    -> EXECUTE/implement  ← 提案 X
#   VERIFY/improve(fail,iter<limit)      -> EXECUTE/improve     ← 提案 X
#   VERIFY/implement(fail,iter>=limit)   -> TRIAGE/triage       ← 提案 X (強制合流)
#   VERIFY/improve(fail,iter>=limit)     -> TRIAGE/triage       ← 提案 X (強制合流)
#   INTEGRATE/*        -> COMPLETE/(維持)
#   COMPLETE/implement -> TRIAGE/triage
#   TRIAGE/triage(P1+P2=0)               -> COMPLETE/implement
#   TRIAGE/triage(P1+P2>0,gate=true)     -> CLARIFY/improve
#   CLARIFY/improve                      -> DESIGN/improve
#   COMPLETE/improve(P>0,iter<3)         -> TRIAGE/triage
#   COMPLETE/improve(P>0,iter>=3)        -> ESCALATION/improve
#   COMPLETE/improve(P=0)                -> COMPLETE/implement

next_sub=""
case "$cur_phase/$cur_sub -> $next_phase" in
  "CLARIFY/implement -> DESIGN")
    next_sub="implement" ;;
  "VERIFY/implement -> EXECUTE")
    next_sub="implement" ;;
  "VERIFY/improve -> EXECUTE")
    next_sub="improve" ;;
  "VERIFY/implement -> TRIAGE")
    next_sub="triage" ;;
  "VERIFY/improve -> TRIAGE")
    next_sub="triage" ;;
  "COMPLETE/implement -> TRIAGE")
    next_sub="triage" ;;
  "TRIAGE/triage -> COMPLETE")
    next_sub="implement" ;;
  "TRIAGE/triage -> CLARIFY")
    next_sub="improve" ;;
  "CLARIFY/improve -> DESIGN")
    next_sub="improve" ;;
  "COMPLETE/improve -> TRIAGE")
    next_sub="triage" ;;
  "COMPLETE/improve -> ESCALATION")
    next_sub="improve" ;;
  "COMPLETE/improve -> COMPLETE")
    next_sub="implement" ;;
  *)
    # DESIGN/*, PLAN/*, EXECUTE/*, VERIFY/*, INTEGRATE/* は sub_phase 維持
    next_sub="$cur_sub" ;;
esac

echo "$next_sub"
