#!/usr/bin/env bash
# scripts/worktree.sh — タスク用 worktree のライフサイクル管理（Orchestrator が使用）
#
# 使い方:
#   bash scripts/worktree.sh create <task-id> [--base <branch>]
#                                                    # worktree 作成＋state.json 更新（IN_PROGRESS）
#                                                    # --base 指定時は依存タスクのブランチをベースに切る
#   bash scripts/worktree.sh finish <task-id> [msg]  # worktree 内コミット＋push＋COMPLETE（マージしない）
#   bash scripts/worktree.sh push   <task-id>        # 現在の worktree ブランチを保全 push（途中保全用）
#   bash scripts/worktree.sh abort  <task-id>        # 強制破棄＋ブランチ削除（失敗時）
#
# 依存タスクの直列実行（sprint-2 報告 4-3）:
#   per-task マージ廃止（INTEGRATE 一括）と worktree 分離を併用すると、後続タスクは前タスク成果に
#   依存するのに、メイン HEAD からブランチを切ると前タスク成果を参照できずコンパイル不能になる。
#   create --base worktree-<前タスク> で、finish 済み（worktree 内コミット＋push 済み）の前タスク
#   ブランチをベースに後続 worktree を切れば、後続が前タスク成果の上で実装・コンパイルできる。
#
# 設計（ARCHITECTURE_RETROSPECTIVE 2-1）:
#   EXECUTE 中はタスクごとの root マージを行わない。finish は worktree 内ローカルコミット＋
#   保全 push＋status=COMPLETE に留め、root への統合は VERIFY 通過後の INTEGRATE フェーズで
#   V2 の integrator エージェントが COMPLETE ブランチを depends_on 順に一括マージする。これにより状態機械の手順と
#   強制レイヤー（マージは INTEGRATE 窓のみ）が自然に一致し、「phase の一時詐称」が不要になる。

set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
STATE_FILE="$ROOT/sprint/state.json"

# 共通 push リトライヘルパ（IH-W5）。on-stop.sh の保全 push と同一実装を共用する。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_push.sh"
# 共通 state 更新ヘルパ（PT0-1）。flock 付き update_state を共用する。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_state.sh"

CMD="${1:-}"; TASK="${2:-}"
[ -z "$CMD" ] || [ -z "$TASK" ] && { echo "使い方: worktree.sh {create|finish|push|abort} <task-id> [msg|--base <branch>]" >&2; exit 1; }

# 残りの引数を解釈する: create は --base <branch>（依存ベース指定）、finish はコミットメッセージ。
BASE=""
MSG=""
shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    *) MSG="$1"; shift ;;
  esac
done

WT_REL=".claude/worktrees/$TASK"
WT_ABS="$ROOT/$WT_REL"
# ブランチ名（stale worktree-* 衝突根絶・narou-reader feedback C / §3 P1）:
# create は未使用名を選び直す（後述 pick_unused_branch）。それ以外（finish/push/abort）は
# state.json に記録済みの実名を使う（create が衝突回避で -rN を選んでいても追従する）。
BRANCH="worktree-$TASK"
if [ "$CMD" != "create" ]; then
  RECORDED=$(jq -r --arg t "$TASK" '.tasks[$t].branch // empty' "$STATE_FILE" 2>/dev/null || true)
  [ -n "$RECORDED" ] && BRANCH="$RECORDED"
fi

# root の gitignore 対象の環境ファイルを新規 worktree へ伝播する（sprint-2 報告／retro 4-3）。
# git worktree add は未追跡/.gitignore 対象ファイル（例: Android の local.properties）を
# リンクド worktree へコピーしないため、各 Worker が worktree 内で個別に用意しないとビルドできない。
# 対象は SPRINT_WORKTREE_ENV_FILES（空白区切り）で上書き可能。既定は local.properties と .env。
copy_env_files() {
  local dest="$1"
  local files="${SPRINT_WORKTREE_ENV_FILES:-local.properties .env}"
  local f
  for f in $files; do
    if [ -f "$ROOT/$f" ] && [ ! -e "$dest/$f" ]; then
      mkdir -p "$dest/$(dirname "$f")"
      cp "$ROOT/$f" "$dest/$f" && echo "環境ファイルを worktree へ伝播: $f"
    fi
  done
}

# 未使用のブランチ名を選ぶ（stale worktree-* 衝突根絶・narou-reader feedback C / §3 P1）。
# 固定名がローカル/origin に既存だと、再開・再試行で別歴史を push する際に非 fast-forward で
# reject される（--force-with-lease は auto mode 分類器で不可）。未使用名（必要なら -rN）を選んで
# 衝突を原理的に避ける。採用名は state.json.tasks[<id>].branch に記録され、integrate/reopen が追従する。
pick_unused_branch() {
  local base="$1" name="$1" n=1
  while git -C "$ROOT" rev-parse --verify --quiet "$name" >/dev/null 2>&1 \
     || git -C "$ROOT" rev-parse --verify --quiet "origin/$name" >/dev/null 2>&1; do
    name="${base}-r${n}"; n=$((n + 1))
  done
  printf '%s' "$name"
}

# ブランチを origin へ保全 push する（ベストエフォート・失敗は致命的にしない）。
# クラウドの ephemeral 性で未 push のローカル成果が消えるのを防ぐ（3-1）。
# 成功時は last_pushed_at を state.json に記録する（再開時の整合性検証ポインタ・1-1）。
push_branch() {
  local task="$1" branch="$2"
  local rc=0
  sprint_push_with_retry "$ROOT" "$branch" || rc=$?
  case "$rc" in
    0)
      local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
      update_state '.tasks[$t].last_pushed_at = $at' --arg t "$task" --arg at "$now"
      echo "保全 push 完了: $branch"
      ;;
    2)
      echo "（remote 未設定のため push 省略: $branch）" >&2
      ;;
    *)
      echo "警告: $branch の push に失敗（ネットワーク等）。worktree 内コミットは保持されています。" >&2
      ;;
  esac
  return 0
}

case "$CMD" in
  create)
    # stale 衝突根絶: 固定名が（ローカル/origin に）既存なら未使用名（-rN）を選ぶ。
    BRANCH=$(pick_unused_branch "worktree-$TASK")
    if [ -n "$BASE" ]; then
      # 依存タスクのブランチ（例: worktree-task-001）をベースに worktree を切る（4-3）。
      # 前タスクが finish で worktree 内コミット＋push 済みであることが前提。
      # ベースがローカルに無ければ origin から取得を試みる（ephemeral 再開対策）。
      if ! git -C "$ROOT" rev-parse --verify "$BASE" >/dev/null 2>&1; then
        git -C "$ROOT" fetch origin "$BASE" >/dev/null 2>&1 || true
        git -C "$ROOT" rev-parse --verify "origin/$BASE" >/dev/null 2>&1 && BASE="origin/$BASE"
      fi
      git -C "$ROOT" worktree add "$WT_REL" -b "$BRANCH" "$BASE" >/dev/null
      update_state \
        '.tasks[$t] = ((.tasks[$t] // {}) + {worktree:$wt, branch:$br, base:$base, status:"IN_PROGRESS", tdd_phase:"RED", failure_count:0, merged:false})' \
        --arg t "$TASK" --arg wt "$WT_REL" --arg br "$BRANCH" --arg base "$BASE"
      echo "worktree 作成: $WT_REL（branch=$BRANCH, base=$BASE, status=IN_PROGRESS, tdd_phase=RED）"
    else
      git -C "$ROOT" worktree add "$WT_REL" -b "$BRANCH" >/dev/null
      update_state \
        '.tasks[$t] = ((.tasks[$t] // {}) + {worktree:$wt, branch:$br, status:"IN_PROGRESS", tdd_phase:"RED", failure_count:0, merged:false})' \
        --arg t "$TASK" --arg wt "$WT_REL" --arg br "$BRANCH"
      echo "worktree 作成: $WT_REL（branch=$BRANCH, status=IN_PROGRESS, tdd_phase=RED）"
    fi
    # gitignore 対象の環境ファイル（local.properties 等）を worktree へ伝播する（4-3）。
    copy_env_files "$WT_ABS"
    # PT3: per-task の頻繁更新フィールドはタスクローカル（sprint/tasks/<id>.status.json）が真実。
    # 初期値（tdd_phase=RED, failure_count=0）を初期化する。state.json の同名フィールドは初期ミラー。
    update_task_status "$TASK" '. + {tdd_phase:"RED", failure_count:0}'
    ;;
  finish)
    MSG="${MSG:-feat: $TASK 完了}"
    git -C "$WT_ABS" add -A
    # 制御面（sprint/state.json）は post-task.sh 等のフックが worktree 内で書き換える。
    # これをタスクブランチに混ぜると main の制御面とマージ競合し、INTEGRATE 偽陽性
    # ESCALATION の温床になる（sprint-1 振り返り Problem「worktree 側 state.json のフック汚染」）。
    # ステージから外し、worktree の HEAD 状態へ復元してから成果物のみコミットする。
    # PT3: タスクローカル状態（sprint/tasks/*.status.json）は gitignore 済みの揮発スクラッチで、
    # 耐久値は reduce_task_status が state.json へ集約する（state.json が真実源）。git add -A では
    # ステージされないが、過去追跡分・手動 add の取りこぼし対策として明示 reset でも外す（防御的）。
    # これで root↔worktree 双方が同名 status.json を commit して add/add 競合する事故を根絶する（sprint-9 教訓）。
    git -C "$WT_ABS" reset -q -- sprint/state.json sprint/tasks 2>/dev/null || true
    git -C "$WT_ABS" checkout -q -- sprint/state.json 2>/dev/null || true
    git -C "$WT_ABS" checkout -q -- sprint/tasks 2>/dev/null || true
    # 変更がある場合のみコミット（worktree 内ローカルコミット。root へはマージしない）。
    if ! git -C "$WT_ABS" diff --cached --quiet; then
      git -C "$WT_ABS" commit -m "$MSG" >/dev/null
    fi
    LAST_COMMIT=$(git -C "$WT_ABS" rev-parse HEAD 2>/dev/null || echo "")
    # status=COMPLETE（=実装・レビュー済み、INTEGRATE で統合待ち）。branch / worktree は残す。
    # last_commit は再開時の state↔実体 整合性検証に使う（1-1）。
    update_state '.tasks[$t].status = "COMPLETE" | .tasks[$t].last_commit = $c' \
      --arg t "$TASK" --arg c "$LAST_COMMIT"
    echo "worktree 内コミット完了: $TASK（status=COMPLETE, branch=$BRANCH 保持・INTEGRATE で統合）"
    # ephemeral 保全: ブランチを push（ベストエフォート）。
    push_branch "$TASK" "$BRANCH"
    ;;
  push)
    [ -d "$WT_ABS" ] || { echo "worktree が存在しません: $WT_ABS" >&2; exit 1; }
    push_branch "$TASK" "$BRANCH"
    ;;
  abort)
    git -C "$ROOT" worktree remove --force "$WT_REL" >/dev/null 2>&1 || true
    git -C "$ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
    update_state '.tasks[$t].status = "FAILED"' --arg t "$TASK"
    echo "worktree 破棄: $TASK（status=FAILED）"
    ;;
  *)
    echo "不明なコマンド: $CMD" >&2; exit 1 ;;
esac
