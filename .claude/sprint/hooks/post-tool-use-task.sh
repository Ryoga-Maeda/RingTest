#!/usr/bin/env bash
# .claude/sprint/hooks/post-tool-use-task.sh — V2 PostToolUse(Task) フック
#
# 目的:
#   Task ツール（subagent_type 指定の Agent 呼び出し）完了直後に
#   1) output-contract を検査し、違反していれば agent を quarantine
#   2) phase-advance を駆動する。
#   3) subagent_heartbeats[<agent>] を削除してハンドシェイクを完結させる。
#   Worker / Reviewer / Evaluator 等の終了をトリガに、
#   Orchestrator が次手を受け取れるようにする。
#
# 不変条件:
#   - v2_active != true のときは silent exit 0（v1 並走に影響しない）
#   - subagent_type が空（= Task ではない PostToolUse）でも silent exit 0
#   - contract yaml が存在しない agent は検査スキップして phase-advance のみ
#   - phase-advance.sh 内部でデバウンスされるので、連続発火しても安全
#   - heartbeat 削除は契約 PASS / FAIL いずれの経路でも必ず実行される
#     （quarantine = subagent_health への記録、heartbeat 削除 = 完了印 と責務分離）
set -euo pipefail

# _state.sh の update_state を使えるよう ROOT/STATE_FILE をセットして source する。
# 既存の `sprint/state.json` 相対参照は v2_active 判定で維持し、heartbeat 更新だけ
# 原子的 helper を使う（並列フックでのロストアップデート防止）。
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$ROOT/sprint/state.json"
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_state.sh" 2>/dev/null || true

input=$(cat)
tool=$(echo "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")
[ -n "$tool" ] || exit 0

# heartbeat 削除ヘルパ。契約違反の早期 exit 経路でも呼ぶため関数化する。
# WHY: quarantine は subagent_health へ「異常終了」を記録するのみで、heartbeat は
#      「起動中」マーカーとして残り続ける。契約 FAIL 経路でも heartbeat を消さないと
#      check-heartbeats.sh が T1 超過後にオーファンとして再殺しに来てしまうため、
#      責務分離（health=履歴 / heartbeat=ライブ状態）の整合を保つ。
__clear_heartbeat() {
  local a="$1"
  [ -n "$a" ] || return 0
  # del() 経路で当該キーを除去。subagent_heartbeats が無い state でも no-op。
  update_state \
    '.subagent_heartbeats = ((.subagent_heartbeats // {}) | with_entries(select(.key != $a)))' \
    --arg a "$a" 2>/dev/null || true
}

# v2_active のみ動作
if [ -f sprint/state.json ] && [ "$(jq -r '.v2_active // false' sprint/state.json 2>/dev/null)" = "true" ]; then
  agent="$tool"
  contract=".claude/sprint/output-contracts/${agent}.yaml"

  if [ -n "$agent" ] && [ -f "$contract" ]; then
    # サブエージェント出力テキストは tool_response を文字列化して渡す
    out_tmp=$(mktemp)
    echo "$input" | jq -r '.tool_response | tostring' > "$out_tmp" 2>/dev/null || echo "" > "$out_tmp"

    if ! SPRINT_AGENT_OUTPUT="$out_tmp" bash scripts/verify-output-contract.sh "$contract" 2>/dev/null; then
      # 違反検知 → quarantine してから phase-advance を呼ぶ
      bash scripts/quarantine-agent.sh "$agent" >/dev/null 2>&1 || true
      rm -f "$out_tmp"

      # 契約違反でも heartbeat は完了印として必ず削除する（オーファン誤検知防止）。
      __clear_heartbeat "$agent"

      # Orchestrator へ違反を通知
      jq -nc --arg a "$agent" '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: ("output-contract 違反検知。\($a) を quarantine します。phase-advance.sh が bypass 経路を提示します。")
        }
      }'

      # phase-advance は走らせる（次手を提示するため）
      bash .claude/sprint/hooks/phase-advance.sh >/dev/null 2>&1 || true
      exit 0
    fi
    rm -f "$out_tmp"
  fi

  # 契約 PASS（or contract 不在）経路でも heartbeat を削除してから phase-advance へ。
  __clear_heartbeat "$agent"

  bash .claude/sprint/hooks/phase-advance.sh
fi
