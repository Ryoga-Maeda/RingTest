#!/usr/bin/env bash
# R3: テスト改変禁止 — テストファイルへの Edit を tdd_phase != RED のとき deny
# exit 0 = 許可 / exit 1 = 拒否 / 判定不能 = exit 1（fail-closed）
#
# 入力（環境変数）: FILE, TOOL, STATE_FILE

[ -z "${FILE:-}" ] && exit 0
# Edit、または Bash 経由の既存ファイル書換（リダイレクト/sed -i 等で抽出された対象）を検査。
# 新規 Write はテスト新規作成（RED 工程）なので対象外。
case "${TOOL:-}" in
  Edit|Bash) ;;
  *) exit 0 ;;
esac

# テストファイルか判定する。
# 部分文字列マッチ（旧 *test*）は `latest` / `contest` / `attestation` 等の無関係語を
# 誤検知するため、test/spec を「パスセグメント」または「ファイル名トークン」として
# 現れる場合のみテストとみなす（ARCHITECTURE_RETROSPECTIVE 3-2）。
is_test_file() {
  local path="$1"
  local base dir
  base=$(basename -- "$path")
  dir=$(dirname -- "$path")

  # 1) ファイル名トークン: foo.test.ts / foo_test.go / foo.spec.tsx / test_foo.py / spec_foo.rb /
  #    ちょうど test.ext / spec.ext。区切り（. _ -）でトークン化して test/spec が現れるか判定。
  case "$base" in
    *.test.*|*.spec.*|*_test.*|*_spec.*|*-test.*|*-spec.*) return 0 ;;
    test_*|spec_*|test-*|spec-*) return 0 ;;
    test.*|spec.*) return 0 ;;
    Test*.*|Spec*.*) return 0 ;;        # JVM 系: FooTest は別途下で、ここは先頭 Test/Spec
    *Test.*|*Spec.*|*Tests.*|*Specs.*) return 0 ;;  # JVM/各種: FooTest.kt / FooSpec.scala
  esac

  # 2) パスセグメント: .../test/... .../tests/... .../spec/... .../__tests__/... 等の
  #    ディレクトリ配下。スラッシュ区切りでセグメント一致を見る（`latest/` は不一致）。
  case "/$dir/" in
    */test/*|*/tests/*|*/spec/*|*/specs/*|*/__tests__/*|*/__test__/*|*/testing/*) return 0 ;;
  esac

  return 1
}

if ! is_test_file "$FILE"; then
  exit 0    # テストファイル以外は pass
fi

# 並列対応（PT1-3 / B2）: 帰属を current_task（単一）からパス逆引きへ切り替える。
# テストファイルが属する worktree のタスクの tdd_phase で判定する（取り違え防止）。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/policy/checks/_task_from_path.sh" 2>/dev/null || {
  echo "R3 違反: 逆引きヘルパ(_task_from_path.sh)を読めずポリシー判定不能（fail-closed）"; exit 1; }

TASK=$(task_from_file_or_cwd "$FILE" "${CWD:-}") || TASK=""
if [ -z "$TASK" ]; then
  echo "R3 違反: テストファイルの担当タスクを特定できません（worktree 外）。テスト改変は禁止です: $FILE"
  exit 1
fi

TDD_PHASE=$(task_field "$TASK" tdd_phase UNKNOWN)
if [ "$TDD_PHASE" != "RED" ]; then
  echo "R3 違反: タスク '$TASK' は tdd_phase=$TDD_PHASE です。テスト改変は RED フェーズのみ許可されます"
  exit 1
fi
exit 0
