#!/usr/bin/env bash
# .claude/sprint/hooks/phase-advance.sh — V2 フェーズ前進フック
#
# 目的:
#   SessionStart / PostToolUse(Task) / UserPromptSubmit から呼ばれ、
#   apply → eval の順で実行し、eval 出力を Orchestrator へ注入する。
#   デバウンス機構を内包し、短時間の連続発火を間引く。
#
# stdin : Claude Code フックランタイムが渡す JSON（未参照）
# stdout: {"hookSpecificOutput": {"hookEventName": "<event>", "additionalContext": "<eval 出力>"}}
# 副作用:
#   - scripts/phase-advance-apply.sh 実行で state.json の phase/sub_phase/improve_iteration を更新
#   - state.json.phase_advance_last_fired_at を現在時刻(epoch ms)で更新
#
# デバウンス:
#   - 環境変数 SPRINT_PHASE_ADVANCE_DEBOUNCE_MS（既定 1000）を読む
#   - 前回発火時刻との差分が閾値以下なら何も出力せず exit 0
#
# 不変条件:
#   - v2_active != true のときは何もしない（v1 並走のため）
#   - state.json 未初期化なら何もしない
#   - apply を先に呼ぶことで、eval は常に「遷移後の state」を見る
set -euo pipefail

STATE=sprint/state.json
[ -f "$STATE" ] || exit 0  # 未初期化なら何もしない

# v2 でないときは何もしない（v1 並走のため）
v2=$(jq -r '.v2_active // false' "$STATE" 2>/dev/null || echo "false")
[ "$v2" = "true" ] || exit 0

# デバウンス判定
THRESH=${SPRINT_PHASE_ADVANCE_DEBOUNCE_MS:-1000}
NOW_MS=$(($(date +%s%N) / 1000000))
LAST=$(jq -r '.phase_advance_last_fired_at // 0' "$STATE" 2>/dev/null || echo "0")
if [ $((NOW_MS - LAST)) -lt "$THRESH" ]; then
  exit 0  # silently drop
fi

# 1) phase 遷移を atomic に適用（書込）
bash scripts/phase-advance-apply.sh >/dev/null

# 2) 現状の state を読み、次の一手プロンプトを生成
OUT=$(bash scripts/phase-advance-eval.sh)

# 3) phase_advance_last_fired_at を更新（flock で書込競合を防ぐ）
tmp=$(mktemp)
(
  flock -x 9
  jq --argjson t "$NOW_MS" '.phase_advance_last_fired_at = $t' "$STATE" > "$tmp"
  mv "$tmp" "$STATE"
) 9<"$STATE"

# 4) フック仕様（§0.4）に従って Orchestrator へ注入
hook_event="${CLAUDE_HOOK_EVENT:-PhaseAdvance}"
printf '%s' "$OUT" | jq -Rs --arg ev "$hook_event" '{
  hookSpecificOutput: {
    hookEventName: $ev,
    additionalContext: .
  }
}'
