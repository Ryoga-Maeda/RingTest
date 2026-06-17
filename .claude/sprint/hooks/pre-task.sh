#!/usr/bin/env bash
# .claude/sprint/hooks/pre-task.sh — PreToolUse ゲート入口（fail-closed ディスパッチャ）
# P1.5-2: policy/checks/*.sh を順に実行し、1つでも非ゼロ終了なら deny を返す。
#
# Bash 迂回対策（設計書 §7.6「Bash 経由の迂回も検査」）:
#   Bash ツールには file_path が無いため、コマンド文字列から「書込先パス候補」を
#   抽出し（リダイレクト > / >>、tee / sponge、mv / cp の宛先、dd of=、sed -i）、
#   各候補に対して経路ベースのチェック（R1/R2/R3/R5）を実行する。
#   抽出できない（=ファイルを書かない）コマンドは経路チェック対象外。
#   ※ ベストエフォート。クォート・変数展開を多用した難読コマンドは取りこぼしうるため、
#     最終防衛線として CI（Layer 4）・pre-commit（Layer 3）で再検証する。

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_guard.sh" 2>/dev/null || exit 0
# 非アクティブ（OFF / state.json 不在 / 壊れた JSON）なら _guard.sh が exit 0 済み

INPUT=$(cat)

deny() {
  # deny JSON を返して PreToolUse でブロックさせる
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# jq が無ければ判定不能 → fail-closed（deny）
command -v jq >/dev/null 2>&1 || deny "[fail-closed] jq が利用できないためポリシー判定不能"

# state.json が破損して読めないなら判定不能 → fail-closed（deny）
if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
  deny "[fail-closed] sprint/state.json が破損しておりポリシー判定不能"
fi

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
# CWD: 呼び出し元の作業ディレクトリ（PT1: パスベース帰属の補助源）。
# 並列で書込先の無いコマンド（テスト実行等）を担当 worktree へ帰属するため、
# また R2 の相互汚染検知（CWD と FILE が別 worktree なら deny）のために使う。
# Claude Code の PreToolUse 入力に cwd があれば使い、無ければ空（縮退）。
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
export TOOL FILE CMD CWD ROOT STATE_FILE

# Bash コマンドから書込先パス候補を抽出する（ベストエフォート）。
extract_bash_targets() {
  local cmd="$1"
  {
    # 1) リダイレクト  > path / >> path（先頭の任意 fd 番号は無視）
    printf '%s\n' "$cmd" | grep -oE '[0-9]*>>?[[:space:]]*[^[:space:];|&<>()]+' \
      | sed -E 's/^[0-9]*>>?[[:space:]]*//'
    # 2) tee / sponge の宛先（オプションを読み飛ばし、最初の非オプション語）
    printf '%s\n' "$cmd" | tr ';|&' '\n' | awk '
      { for (i=1;i<=NF;i++) {
          if ($i=="tee" || $i=="sponge") {
            for (j=i+1;j<=NF;j++) { if ($j !~ /^-/) { print $j; break } }
          }
        } }'
    # 3) dd of=path
    printf '%s\n' "$cmd" | grep -oE '\bof=[^[:space:];|&<>()]+' | sed -E 's/^of=//'
    # 4) mv / cp の宛先（セグメント末尾の語）
    printf '%s\n' "$cmd" | tr ';|&' '\n' | awk '
      $1=="mv" || $1=="cp" { print $NF }'
    # 5) sed -i の対象ファイル（-i 系オプションがある場合の非オプション引数）
    printf '%s\n' "$cmd" | tr ';|&' '\n' | awk '
      $1=="sed" {
        inplace=0
        for (i=2;i<=NF;i++) if ($i ~ /^-i/) inplace=1
        if (inplace) for (i=2;i<=NF;i++) if ($i !~ /^-/) print $i
      }'
  } 2>/dev/null | sed '/^$/d' | sort -u
}

# 経路ベースのチェックに渡す「対象パス」の集合を決める。
declare -a TARGETS=()
if [ "$TOOL" = "Bash" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] && TARGETS+=("$t")
  done < <(extract_bash_targets "$CMD")
else
  [ -n "$FILE" ] && TARGETS+=("$FILE")
fi
# 1つも対象が無い場合も、FILE 非依存のチェック（R0/R4）を1回は走らせる。
[ "${#TARGETS[@]}" -eq 0 ] && TARGETS=("")

CHECKS_DIR="$ROOT/.claude/sprint/policy/checks"

# checks/*.sh を辞書順に実行。各対象パスについて評価し、1つでも失敗したら deny（fail-closed）。
# 各チェックは冪等で、自分に無関係な対象では exit 0 する設計。
shopt -s nullglob
for chk in "$CHECKS_DIR"/*.sh; do
  [ -f "$chk" ] || continue
  base=$(basename "$chk")
  case "$base" in _*) continue ;; esac   # _ で始まる補助スクリプトは除外
  for tgt in "${TARGETS[@]}"; do
    REASON=$(FILE="$tgt" bash "$chk" "$INPUT" 2>&1) && continue
    deny "[ポリシー違反: ${base%.sh}] $REASON"
  done
done

# 全チェック通過 → 無出力で exit 0（= allow）
exit 0
