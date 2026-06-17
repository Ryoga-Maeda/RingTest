#!/usr/bin/env bash
# .claude/sprint/hooks/_control_commit.sh — 制御面（state/checkpoint）を制御ブランチへ
# plumbing でコミット＆push する共通ヘルパ（IH-W6）。
#
# 中断時（on-stop のステップ4.5）と、閾値の初回跨ぎ検出時（post-task の IH-W1: ラグ短縮）が
# 共用する。作業ツリー・現在ブランチ（main 等）を切り替えず、固定命名規約
# SPRINT_CONTROL_BRANCH（既定 sprint/<sprint_id>）へ制御面ファイルだけを積む
# （plumbing: 一時 index + write-tree + commit-tree + update-ref）。main は汚さない。
# 冪等: state.json が制御ブランチ先端と同一なら no-op（checkpoint.md のタイムスタンプ変動
# だけでコミットを打たない。checkpoint は state の決定論的派生物）。
#
# 依存: ROOT, STATE_FILE（呼び出し元が設定）。CHECKPOINT_FILE は未設定なら既定値を使う。
# push は _push.sh の sprint_push_with_retry を最善努力で流用する。

sprint_control_plane_commit() {
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0

  # push ヘルパ（sprint_push_with_retry）を最善努力で読む（未 source でも commit は進める）。
  if ! command -v sprint_push_with_retry >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    [ -f "$ROOT/.claude/sprint/hooks/_push.sh" ] && source "$ROOT/.claude/sprint/hooks/_push.sh" 2>/dev/null || true
  fi

  local checkpoint_file CTRL_SPRINT_ID CONTROL_BRANCH CONTROL_REF NEW_STATE_BLOB OLD_STATE_BLOB
  checkpoint_file="${CHECKPOINT_FILE:-$ROOT/sprint/checkpoint.md}"
  CTRL_SPRINT_ID=$(jq -r '.sprint_id // "sprint-1"' "$STATE_FILE" 2>/dev/null || echo "sprint-1")
  CONTROL_BRANCH="${SPRINT_CONTROL_BRANCH:-sprint/$CTRL_SPRINT_ID}"
  CONTROL_REF="refs/heads/$CONTROL_BRANCH"
  NEW_STATE_BLOB=$(git -C "$ROOT" hash-object "$STATE_FILE" 2>/dev/null || echo "")
  OLD_STATE_BLOB=""
  if git -C "$ROOT" rev-parse --verify "$CONTROL_REF" >/dev/null 2>&1; then
    OLD_STATE_BLOB=$(git -C "$ROOT" rev-parse "$CONTROL_REF:sprint/state.json" 2>/dev/null || echo "")
  fi
  # 冪等: 差分が無ければコミットしない。
  [ -n "$NEW_STATE_BLOB" ] && [ "$NEW_STATE_BLOB" != "$OLD_STATE_BLOB" ] || return 0

  local CTRL_PHASE CTRL_INDEX CTRL_TREE CTRL_MSG CTRL_COMMIT ctrl_push_rc
  local CTRL_PARENT=() CTRL_FILES=()
  CTRL_PHASE=$(jq -r '.phase // "UNKNOWN"' "$STATE_FILE" 2>/dev/null || echo "UNKNOWN")
  CTRL_INDEX="$ROOT/.git/sprint-control-index"   # 本 index（.git/index）と分離した一時 index
  rm -f "$CTRL_INDEX"
  if git -C "$ROOT" rev-parse --verify "$CONTROL_REF" >/dev/null 2>&1; then
    # 既存の制御ブランチツリーを基にする（state/checkpoint 以外の追跡物を保つ・親に持つ）。
    GIT_INDEX_FILE="$CTRL_INDEX" git -C "$ROOT" read-tree "$CONTROL_REF" 2>/dev/null || true
    CTRL_PARENT=(-p "$CONTROL_REF")
  fi
  CTRL_FILES=(sprint/state.json)
  [ -f "$checkpoint_file" ] && CTRL_FILES+=(sprint/checkpoint.md)
  [ -d "$ROOT/sprint/archive" ] && CTRL_FILES+=(sprint/archive)
  GIT_INDEX_FILE="$CTRL_INDEX" git -C "$ROOT" add -- "${CTRL_FILES[@]}" 2>/dev/null || true
  CTRL_TREE=$(GIT_INDEX_FILE="$CTRL_INDEX" git -C "$ROOT" write-tree 2>/dev/null || echo "")
  rm -f "$CTRL_INDEX"
  [ -n "$CTRL_TREE" ] || return 0

  CTRL_MSG="chore(sprint): checkpoint $CTRL_SPRINT_ID @ $CTRL_PHASE"
  CTRL_COMMIT=$(git -C "$ROOT" commit-tree "$CTRL_TREE" "${CTRL_PARENT[@]}" -m "$CTRL_MSG" 2>/dev/null || echo "")
  [ -n "$CTRL_COMMIT" ] || return 0
  # update-ref のみで制御ブランチ先端を進める。HEAD（現在ブランチ）は触らない。
  git -C "$ROOT" update-ref "$CONTROL_REF" "$CTRL_COMMIT"
  echo "制御面 checkpoint コミット: $CONTROL_BRANCH（$CTRL_MSG）" >&2

  # origin へ保全 push（IH-W5 リトライ共用）。失敗してもローカルコミットは残り、次回が
  # 同一コミットを冪等に再 push するため警告のみとする。
  ctrl_push_rc=0
  if command -v sprint_push_with_retry >/dev/null 2>&1; then
    sprint_push_with_retry "$ROOT" "$CONTROL_BRANCH" || ctrl_push_rc=$?
    [ "$ctrl_push_rc" != "0" ] && [ "$ctrl_push_rc" != "2" ] \
      && echo "警告: 制御ブランチ $CONTROL_BRANCH の push に失敗（次回 on-stop で再 push）" >&2
  fi
  return 0
}
