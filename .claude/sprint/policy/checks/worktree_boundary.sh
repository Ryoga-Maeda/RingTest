#!/usr/bin/env bash
# R2: worktree 境界強制 — 書込先が進行中タスクの worktree 配下かチェック
# exit 0 = 許可 / exit 1 = 拒否 / 判定不能 = exit 1（fail-closed）
#
# 入力（環境変数）: FILE, STATE_FILE, ROOT
#
# 例外:
#   - $ROOT/sprint/ 配下（制御面: state.json/checkpoint.md 等）は本チェックの対象外。
#     これらは R5（gate_approval）と R0（self_protect）で別途保護される。
#   - phase==INTEGRATE は「統合作業窓」。worktree をまとめ root を整えるフェーズのため、
#     root 直下の編集（ソース含む）を許可する（ARCHITECTURE_RETROSPECTIVE 2-3）。
#     統合段階で見つかった CI 不備等の修正を可能にする。安全性は R0/R5 と CI(Layer 4) が担保する。
#
# 判定は FILE（実際の書込先絶対パス）を基点に行う（ARCHITECTURE_RETROSPECTIVE 2-2）。
# 並列対応（PT1-2 / B4）: FILE が属する worktree を一意特定し、それが IN_PROGRESS タスクのもので
# あることを要求する（「いずれかの worktree 内なら許可」の緩和を廃止）。さらに呼び出し元 CWD が
# 別 worktree なら相互汚染として拒否する（Worker A が Worker B の worktree を書くのを検知）。

[ -z "${FILE:-}" ] && exit 0

FILE_REAL=$(realpath -m "$FILE" 2>/dev/null || echo "$FILE")
ROOT_REAL=$(realpath -m "$ROOT" 2>/dev/null || echo "$ROOT")

# プロジェクト外への書き込みは R2 の対象外（worktree 境界はプロジェクト内の規律）。
# 例: Bash の `... > /tmp/out`, `> /dev/null` などを誤って deny しないため。
#     プロジェクト外への危険な書き込みは Layer 0（ツール権限）で防ぐ。
case "$FILE_REAL" in
  "$ROOT_REAL"/*) ;;          # プロジェクト内 → 境界チェックを続行
  *) exit 0 ;;                # プロジェクト外 → 対象外
esac

# 制御面（sprint/ 配下）は対象外
case "$FILE_REAL" in
  "$ROOT_REAL"/sprint/*) exit 0 ;;
esac

# INTEGRATE フェーズは統合作業窓 → root 編集を許可（2-3）。
PHASE=$(jq -r '.phase // ""' "$STATE_FILE" 2>/dev/null)
if [ "$PHASE" = "INTEGRATE" ]; then
  exit 0
fi

# パス逆引きヘルパ（PT1-1）を読む。読めなければ判定不能 → fail-closed。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/policy/checks/_task_from_path.sh" 2>/dev/null || {
  echo "R2 違反: 逆引きヘルパ(_task_from_path.sh)を読めずポリシー判定不能（fail-closed）"; exit 1; }

# FILE が属する worktree のタスクを一意特定する。worktree に属さない書込は拒否。
FILE_TASK=$(task_from_path "$FILE_REAL") || FILE_TASK=""
if [ -z "$FILE_TASK" ]; then
  echo "R2 違反: 担当 worktree 外への書き込み（worktree に属さないパス）: $FILE"
  exit 1
fi

# その worktree のタスクが IN_PROGRESS か（COMPLETE/FAILED の残 worktree への書込は拒否）。
FILE_STATUS=$(task_status "$FILE_TASK")
if [ "$FILE_STATUS" != "IN_PROGRESS" ]; then
  echo "R2 違反: タスク '$FILE_TASK' は IN_PROGRESS ではありません（status=${FILE_STATUS:-未定義}）。その worktree への書き込みは禁止です: $FILE"
  exit 1
fi

# 相互汚染検知（B4）: 呼び出し元 CWD が別 worktree のタスクなら拒否する。
# Worker A（CWD=task-01 worktree）が task-02 worktree へ書く越境を検知する。
# CWD が worktree でない（Orchestrator が root から書く等）場合は越境判定をスキップする。
if [ -n "${CWD:-}" ]; then
  CWD_TASK=$(task_from_path "$CWD") || CWD_TASK=""
  if [ -n "$CWD_TASK" ] && [ "$CWD_TASK" != "$FILE_TASK" ]; then
    echo "R2 違反: 相互汚染の疑い。CWD はタスク '$CWD_TASK' の worktree ですが、書込先は '$FILE_TASK' の worktree です: $FILE"
    exit 1
  fi
fi

exit 0
