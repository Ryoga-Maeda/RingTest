#!/usr/bin/env bash
# .claude/sprint/hooks/on-stop.sh
# Stop フック — 永続化（WIP/checkpoint/制御面コミット）による未完スプリント保全（Ring 2）
#
# 使用量起因の中断・再開は撤去された。本フックは「未完スプリントの再開／クラウド再 clone 再開」
# （②）を支える永続化層のトリガ役に縮約され、run_state を遷移させない（SUSPENDED は廃止）。
#
# 発火トリガ（永続化を行う条件）:
#   - phase 境界（DESIGN/EXECUTE/VERIFY/INTEGRATE 等の進行中フェーズで保全しておく価値がある）
#   - SPRINT_FORCE_SHUTDOWN=1（明示的なシャットダウン指示・runner の poisoning freeze・テスト用）
# Stop フックは Claude が応答を終えるたびに発火するため、毎回 WIP コミット/push すると過剰になる。
# そこで「保全に値する状態」のときだけ永続化する（使用量シグナル依存は撤去済み）。

set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$ROOT/sprint/state.json"
CHECKPOINT_FILE="$ROOT/sprint/checkpoint.md"

# 非アクティブなら no-op
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_guard.sh" 2>/dev/null || exit 0

# 共通 push リトライヘルパ（IH-W5）。worktree/制御面の保全 push が共用する。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_push.sh"
# 共通 state 更新ヘルパ（PT0-1）。flock 付き update_state を共用する。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_state.sh"

# 永続化を行うべきか判定する。
# トリガは「SPRINT_FORCE_SHUTDOWN=1」または「保全に値する進行中フェーズ境界」。
# 進行中フェーズ（DESIGN〜INTEGRATE）は再開時に成果を失わないよう保全する。
# CLARIFY（契約未確定・成果物なし）・COMPLETE（終端）は保全不要。
PHASE=$(jq -r '.phase // "UNKNOWN"' "$STATE_FILE" 2>/dev/null || echo "UNKNOWN")
should_persist=0
if [ "${SPRINT_FORCE_SHUTDOWN:-0}" = "1" ]; then
  should_persist=1
else
  case "$PHASE" in
    DESIGN|EXECUTE|VERIFY|INTEGRATE) should_persist=1 ;;
  esac
fi
if [ "$should_persist" != "1" ]; then
  # 保全不要な作業区切り → 状態を変えずそのまま終了する。
  echo "通常終了（phase=$PHASE）。永続化は不要。" >&2
  exit 0
fi

# ステップ1: dirty な worktree を WIP コミット＋保全 push（IH-W5: リトライ付き）
WORKTREES_DIR="$ROOT/.claude/worktrees"
PERSIST_FAILED_BRANCHES=()
if [ -d "$WORKTREES_DIR" ]; then
  for wt in "$WORKTREES_DIR"/*/; do
    [ -d "$wt" ] || continue
    wt_name=$(basename "$wt")
    # dirty（未コミット変更あり）か確認
    if ! git -C "$wt" diff --quiet 2>/dev/null || \
       ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
      git -C "$wt" add -A 2>/dev/null || true
      # --no-verify: これは harness（Stop フック）による状態保全コミットであり、
      # エージェント向けの pre-commit ゲート（Layer 3）の対象外。worktree 内コミットで
      # pre-commit が state.json を解決できず WIP 保全が静かに失われるのを防ぐ。
      # 境界外の混入は git -C "$wt" のスコープ上ありえず、マージ時に CI(Layer 4)が再検証する。
      git -C "$wt" commit --no-verify -m "checkpoint: WIP in worktree $wt_name" 2>/dev/null || true
      echo "worktree $wt_name をWIPコミット" >&2
    fi
    # ephemeral 保全（ARCHITECTURE_RETROSPECTIVE 3-1 / IH-W5）: WIP ブランチを origin へ
    # リトライ付き push する。未 push のローカル成果がコンテナ破棄で消えるのを防ぐ。
    # 全リトライ失敗したブランチは PERSIST_FAILED_BRANCHES に集約し、後段で state に記録する。
    wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\r' || echo "")
    if [ -n "$wt_branch" ] && [ "$wt_branch" != "HEAD" ]; then
      push_rc=0
      sprint_push_with_retry "$wt" "$wt_branch" || push_rc=$?
      case "$push_rc" in
        0) echo "worktree $wt_name を保全 push（$wt_branch）" >&2 ;;
        2) : ;;  # remote 未設定 → push 省略（ローカル/テスト環境）
        *)
          echo "worktree $wt_name の push 失敗（${SPRINT_PUSH_ATTEMPTS} 回試行・ローカルコミットは保持）" >&2
          PERSIST_FAILED_BRANCHES+=("$wt_branch")
          ;;
      esac
    fi
  done
fi

# 保全 push の失敗有無を state に記録（IH-W5・.resilience 名前空間）。
# 次回 session-start が persist_failed を検出し、再 push と喪失検査を最優先できる。
if [ "${#PERSIST_FAILED_BRANCHES[@]}" -gt 0 ]; then
  BRANCHES_JSON=$(printf '%s\n' "${PERSIST_FAILED_BRANCHES[@]}" | jq -R . | jq -s .)
  update_state '.resilience.persist_failed = true | .resilience.persist_failed_branches = $branches' \
    --argjson branches "$BRANCHES_JSON"
  {
    echo "================================================================"
    echo "⚠️  警告: 次のブランチの保全 push に失敗しました（コンテナ破棄で成果喪失の恐れ）:"
    printf '   - %s\n' "${PERSIST_FAILED_BRANCHES[@]}"
    echo "   次回セッション開始時に再 push と喪失検査を試みます。"
    echo "================================================================"
  } >&2
else
  # push 全成功（または対象なし）→ 過去の persist_failed をクリアする（冪等）。
  update_state '.resilience.persist_failed = false | .resilience.persist_failed_branches = []'
fi

# ステップ1.5: サブエージェント heartbeat の T1 検査（best-effort）。
# stop_reason: None で浮遊したサブエージェントの heartbeat を T1 検知し、
# subagent_health.<agent>.quarantine_until を立てて次セッションへ引き継ぐ。
# 失敗しても on-stop 全体を落とさない（保全フローは継続する）。
if [ -x "$ROOT/scripts/check-heartbeats.sh" ]; then
  ( cd "$ROOT" && bash scripts/check-heartbeats.sh ) >/dev/null 2>&1 || true
fi

# ステップ2: checkpoint.md を state.json から機械生成（上書き）。
# checkpoint が state より古くなる人手依存を排し、タスク表・next_action を state から導出する。
# §11.2 R-2b: 旧 scripts/gen-checkpoint.sh は削除済み。生成ロジックを本フック内にインライン化。
PHASE=$(jq -r '.phase // "UNKNOWN"' "$STATE_FILE" 2>/dev/null || echo "UNKNOWN")
SPRINT_ID=$(jq -r '.sprint_id // "sprint-1"' "$STATE_FILE" 2>/dev/null || echo "sprint-1")
CURRENT_TASK=$(jq -r '.resume_hint.current_task // "なし"' "$STATE_FILE" 2>/dev/null || echo "なし")
NEXT_ACTION=$(jq -r '.resume_hint.next_action // "state.json を確認して継続"' "$STATE_FILE" 2>/dev/null || echo "state.json を確認して継続")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")
READ_FIRST_PATHS=$(jq -r '.resume_hint.read_first[]? // empty' "$STATE_FILE" 2>/dev/null || echo "sprint/state.json")
{
  echo "# チェックポイント"
  echo ""
  echo "> **自動生成ファイル**: Stop フックが応答ターンごとに state.json から再生成・上書きする。"
  echo "> 同セッション内で読み直すと内容が変わるのは正常で、改ざんやプロンプトインジェクションの兆候ではない。真実の源は \`sprint/state.json\`。"
  echo ""
  echo "**記録日時**: $NOW"
  echo "**スプリント**: $SPRINT_ID"
  echo "**フェーズ**: $PHASE"
  echo "**実行中タスク**: $CURRENT_TASK"
  echo ""
  echo "## 再開時の次アクション"
  echo ""
  echo "$NEXT_ACTION"
  echo ""
  echo "## 優先して読むファイル"
  echo ""
  while IFS= read -r path; do
    [ -n "$path" ] && echo "- \`$path\`"
  done <<< "$READ_FIRST_PATHS"
  echo ""
  echo "---"
  echo "*このファイルは自動生成されます（上書き）。詳細は \`sprint/state.json\` を参照してください。*"
} > "$CHECKPOINT_FILE"

# ステップ3: 制御面の永続化（commit & push）— IH-W6
# クラウドの再 clone 再開が state を読む前にブランチを特定できるよう、制御面ファイルだけを
# 固定命名規約 SPRINT_CONTROL_BRANCH へ積む。ロジックは _control_commit.sh に集約し、
# post-task の能動 checkpoint（IH-W1）と共用する。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_control_commit.sh" 2>/dev/null && sprint_control_plane_commit || true

# ステップ4: 正常終了（run_state は触らない＝中断・再開機構は撤去済み）
echo "永続化完了（phase=$PHASE・WIP/checkpoint/制御面を保全）" >&2
exit 0
