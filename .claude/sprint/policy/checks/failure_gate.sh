#!/usr/bin/env bash
# R4: 3回失敗ゲート — failure_count>=3 かつ phase!=ESCALATION なら実装系ツールを deny
# exit 0 = 許可 / exit 1 = 拒否 / 判定不能 = exit 1（fail-closed）
#
# 入力（環境変数）: STATE_FILE, FILE, ROOT

# 制御面（sprint/ 配下: state.json / gate_approvals.json / checkpoint.md 等）への書き込みは
# R4 の対象外とする。3回失敗後に ESCALATION へ遷移するには Orchestrator が state.json.phase を
# 書き換える必要があるが、その書き込み自体まで止めると「ESCALATION に遷移できない」デッドロックに
# 陥る（書き込み時点では phase はまだ ESCALATION でないため）。実装ファイル（worktree 内）への
# 書き込みとテスト実行 Bash は引き続き停止するので、無限ループ遮断の目的は損なわれない。
if [ -n "${FILE:-}" ]; then
  # 相対パス（Bash コマンドから抽出された書込先など）は CWD ではなく ROOT 基準で解決する。
  # これにより、フックの実行カレントディレクトリに依存せず除外判定が安定する。
  case "$FILE" in
    /*) FILE_ABS="$FILE" ;;
    *)  FILE_ABS="${ROOT:-.}/$FILE" ;;
  esac
  FILE_REAL=$(realpath -m "$FILE_ABS" 2>/dev/null || echo "$FILE_ABS")
  ROOT_REAL=$(realpath -m "${ROOT:-.}" 2>/dev/null || echo "${ROOT:-.}")
  case "$FILE_REAL" in
    "$ROOT_REAL"/sprint/*) exit 0 ;;
  esac
fi

PHASE=$(jq -r '.phase // "UNKNOWN"' "$STATE_FILE" 2>/dev/null)
[ "$PHASE" = "ESCALATION" ] && exit 0    # ESCALATION 中は許可

# 並列対応（PT1-4 / B2）: 帰属を current_task（単一）からパス逆引きへ切り替える。
# 書込先 FILE（無ければ CWD）が属する worktree のタスクの failure_count で判定する。
# これで並列の片方が3回失敗しても、無関係なもう片方はブロックされない。
# 逆引きヘルパが無くても pass（R2 が worktree 境界を fail-closed で別途守る）。
# shellcheck disable=SC1090
source "${ROOT:-.}/.claude/sprint/policy/checks/_task_from_path.sh" 2>/dev/null || exit 0

TASK=$(task_from_file_or_cwd "$FILE" "${CWD:-}") || TASK=""
[ -z "$TASK" ] && exit 0    # タスク特定不能 → pass（他チェックに委ねる）

FAILURE_COUNT=$(task_field "$TASK" failure_count 0)
if [ "${FAILURE_COUNT:-0}" -ge 3 ] 2>/dev/null; then
  echo "R4 違反: タスク '$TASK' は ${FAILURE_COUNT}回失敗しています。ESCALATION フェーズに遷移してから再開してください"
  exit 1
fi
exit 0
