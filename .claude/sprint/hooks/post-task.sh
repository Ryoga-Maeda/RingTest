#!/usr/bin/env bash
# .claude/sprint/hooks/post-task.sh — PostToolUse（事後検証・失敗カウンタ自動更新）
# P1.5-4: テスト実行の成否を検知して failure_count を更新（R4 の補助）。

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_guard.sh" 2>/dev/null || exit 0
# 共通 state 更新ヘルパ（PT0-1）。flock 付き update_state（filter 先頭シグネチャ）を共用する。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_state.sh"
# パス逆引きヘルパ（PT1-1）。テスト失敗の帰属をパスベースで決める（B2/B3）。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/policy/checks/_task_from_path.sh" 2>/dev/null || true

INPUT=$(cat)

# FR-3: フック生存カナリア。発火ごとに hook_heartbeat を更新する（フック死亡検知の一次マーカー）。
NOW_HB=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
[ -n "$NOW_HB" ] && update_state '.hook_heartbeat = $h' --arg h "$NOW_HB"

LAST_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
# exit_code は実装により tool_response.exit_code / tool_output.exit_code の両方を許容
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // .tool_output.exit_code // 0' 2>/dev/null)
# CWD: テスト実行時の作業ディレクトリ（担当 worktree に固定されている前提）。帰属の最優先源。
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# テスト失敗/成功の帰属タスクを決める（PT1-5・パスベース。誤帰属より無帰属を選ぶ）。
# 優先順: (1) CWD → (2) コマンド内の worktree パス → (3) in_flight がちょうど1件。
# いずれも引けなければ非ゼロを返し、呼び出し側は state を更新しない（並列での誤帰属を避ける）。
attribute_task() {
  local t seg n only
  if command -v task_from_path >/dev/null 2>&1; then
    if [ -n "${CWD:-}" ] && t=$(task_from_path "$CWD"); then printf '%s\n' "$t"; return 0; fi
    seg=$(printf '%s\n' "$LAST_CMD" | grep -oE '\.claude/worktrees/[^/[:space:]]+' | head -1)
    if [ -n "$seg" ] && t=$(task_from_path "$seg"); then printf '%s\n' "$t"; return 0; fi
  fi
  n=$(jq -r '(.resume_hint.in_flight // []) | length' "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$n" = "1" ]; then
    only=$(jq -r '.resume_hint.in_flight[0] // empty' "$STATE_FILE" 2>/dev/null)
    [ -n "$only" ] && { printf '%s\n' "$only"; return 0; }
  fi
  return 1
}

# テストコマンドの検知 → 帰属タスクの failure_count / tdd_phase を更新
if echo "$LAST_CMD" | grep -qE '\b(test|pytest|jest|go test|cargo test|rspec|phpunit|vitest)\b'; then
  if TASK=$(attribute_task); then
    # PT3: per-task の頻繁更新フィールドはタスクローカル（sprint/tasks/<id>.status.json）へ書く。
    # タスクごとに別ファイルのため、並列の Worker/post-task が同一フィールドを奪い合わない。
    if [ "${EXIT_CODE:-0}" -ne 0 ] 2>/dev/null; then
      # テスト失敗 → failure_count 加算
      update_task_status "$TASK" '.failure_count = ((.failure_count // 0) + 1)'
    else
      # テスト成功（GREEN）→ failure_count リセット ＋ tdd_phase=GREEN
      # 所有権メモ: GREEN はフックが書く。RED/REFACTOR は Worker がタスクローカルを更新する
      # （worker.md「tdd_phase の所有権」参照）。次のテストを書く前に Worker が RED へ戻す。
      update_task_status "$TASK" '.failure_count = 0 | .tdd_phase = "GREEN"'
    fi
  fi
fi

# FR-4 二次（フック内ベストエフォート）: ツール連続失敗カウンタ。tool-call の parse 失敗自体は
# フックが発火しないことが多く取りこぼし前提だが、発火できた範囲のツール失敗を state に記録し、
# 外部監視 (V2: resilience.sh / check-heartbeats.sh) の poisoning 検知の補助材料とする。成功でリセット。
# （レジリエンス用フィールドのため .resilience 名前空間に置く）
if [ "${EXIT_CODE:-0}" -ne 0 ] 2>/dev/null; then
  update_state '.resilience.consecutive_tool_failures = ((.resilience.consecutive_tool_failures // 0) + 1)'
else
  update_state '.resilience.consecutive_tool_failures = 0'
fi

exit 0
