#!/usr/bin/env bash
# state.json を読み、遷移条件を満たす場合に phase/sub_phase を atomic に更新する。
# Orchestrator が state.json を書き換える唯一の窓口。
# 引数なし・環境変数なし。
# 副作用: state.json の atomic 更新 + sprint/phase_log.jsonl への追記
# stdout: 適用した遷移の 1 行ログ（適用なしは空）
# exit code: 0=正常, 1=state.json 不整合
set -euo pipefail

STATE=sprint/state.json
[ -f "$STATE" ] || exit 0

# 不整合検査: phase / sub_phase が読めるか
if ! jq -e '.phase' "$STATE" > /dev/null 2>&1; then
  exit 1
fi
if ! jq -e '.sub_phase' "$STATE" > /dev/null 2>&1; then
  exit 1
fi

cur_phase=$(jq -r '.phase' "$STATE")
cur_sub=$(jq -r '.sub_phase' "$STATE")

new_phase=$(scripts/phase-advance-eval-next-phase.sh)
new_sub=$(scripts/phase-advance-eval-next-sub.sh)

# 冪等性: 既に同じ phase/sub_phase ならば no-op
if [ -z "$new_phase" ]; then
  exit 0
fi
if [ "$new_phase" = "$cur_phase" ] && [ "$new_sub" = "$cur_sub" ]; then
  exit 0
fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)

# improve_iteration++ は「sub_phase が triage に切り替わる遷移」のみ
# (現 sub != "triage" かつ 新 sub == "triage" の場合に +1)
#
# triage_artifacts.entry_reason は TRIAGE 突入経路を記録する診断フィールド。
# bug-hunter は前回 entry_reason を参照して発掘戦略を調整できる:
#   - "complete_implement"   : 通常完走 (実装 COMPLETE 直後)
#   - "verify_unresolved"    : VERIFY ミニループ上限到達 (提案 X)
#   - "complete_improve_loop": 改善フェーズの再 TRIAGE
(
  flock -x 9
  jq --arg p "$new_phase" --arg s "$new_sub" \
     --arg cur_phase "$cur_phase" --arg cur_sub "$cur_sub" '
    .phase = $p
    | .sub_phase = $s
    | (if ($s == "triage") and ($cur_sub != "triage")
        then .improve_iteration = ((.improve_iteration // 0) + 1)
        else . end)
    | (if ($s == "triage") and ($cur_sub != "triage")
        then .triage_artifacts.entry_reason = (
          if   $cur_phase == "VERIFY"   then "verify_unresolved"
          elif $cur_phase == "COMPLETE" and $cur_sub == "implement" then "complete_implement"
          elif $cur_phase == "COMPLETE" and $cur_sub == "improve"   then "complete_improve_loop"
          else "unknown" end)
        else . end)
  ' "$STATE" > "$tmp"
  mv "$tmp" "$STATE"
  mkdir -p sprint
  printf '{"ts":"%s","phase":"%s","sub_phase":"%s"}\n' "$ts" "$new_phase" "$new_sub" >> sprint/phase_log.jsonl
) 9<"$STATE"

echo "applied: $new_phase / $new_sub"
