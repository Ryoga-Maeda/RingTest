#!/usr/bin/env bash
# R0: 自己改変防止 — policy/** と hooks/** への Write/Edit を常時 deny
# exit 0 = 許可 / exit 1 = 拒否
#
# 入力（環境変数）: FILE, TOOL / 引数 $1=ツール呼び出し JSON（Bash コマンド検査用）
#
# Bash ツールによる迂回対策として、コマンド文字列も検査する（多層防御の補強）。

# 1) ファイルパスベースの検査（Write/Edit）
case "${FILE:-}" in
  */.claude/sprint/policy/*|*/.claude/sprint/hooks/*|.claude/sprint/policy/*|.claude/sprint/hooks/*)
    echo "R0 違反: スプリントポリシー・フックの書き換えは禁止です（改ざん防止）: $FILE"
    exit 1
    ;;
esac

# 2) Bash コマンド文字列ベースの検査（リダイレクト等での迂回を防ぐ）
INPUT="${1:-}"
if [ -n "$INPUT" ]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  if echo "$CMD" | grep -qE '\.claude/sprint/(policy|hooks)/'; then
    echo "R0 違反: Bash コマンドによるポリシー・フックへの操作は禁止です（改ざん防止）"
    exit 1
  fi
fi
exit 0
