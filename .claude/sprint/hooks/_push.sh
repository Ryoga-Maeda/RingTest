#!/usr/bin/env bash
# .claude/sprint/hooks/_push.sh
# 共通 push リトライヘルパ（source して使う）。IH-W5。
#
# worktree.sh の保全 push と on-stop.sh の worktree/制御面 push が共用する。
# クラウドの ephemeral 性で未 push のローカル成果が消えるのを防ぐため、
# 一時的なネットワーク失敗をリトライで吸収する。
#
# sprint_push_with_retry <dir> <branch>
#   <dir> のリポジトリで <branch> を origin へ push する。
#   最大 SPRINT_PUSH_MAX_RETRIES 回（既定4）、指数バックオフ
#   （SPRINT_PUSH_BACKOFF_BASE 秒から倍々。既定2 → 2,4,8,16 秒）。
#   実試行回数をグローバル変数 SPRINT_PUSH_ATTEMPTS にセットする
#   （呼び出し側が警告メッセージ・persist_failed 記録に使う）。
#   戻り値: 0=成功 / 1=全失敗 / 2=remote 未設定（push 省略）

sprint_push_with_retry() {
  local dir="$1" branch="$2"
  SPRINT_PUSH_ATTEMPTS=0
  # remote 未設定なら push 省略（ローカル開発・テスト環境）。
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 2
  local max="${SPRINT_PUSH_MAX_RETRIES:-4}"
  local delay="${SPRINT_PUSH_BACKOFF_BASE:-2}"
  while [ "$SPRINT_PUSH_ATTEMPTS" -lt "$max" ]; do
    SPRINT_PUSH_ATTEMPTS=$((SPRINT_PUSH_ATTEMPTS + 1))
    if git -C "$dir" push -u origin "$branch" >/dev/null 2>&1; then
      return 0
    fi
    # 最後の試行後はバックオフ待機しない。
    if [ "$SPRINT_PUSH_ATTEMPTS" -lt "$max" ]; then
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  return 1
}
