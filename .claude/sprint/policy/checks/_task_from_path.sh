#!/usr/bin/env bash
# .claude/sprint/policy/checks/_task_from_path.sh — パス → タスク逆引き（PT1-1）
#
# 並列実行では「今のタスク」が単一でないため、強制レイヤー（R2/R3/R4）・post-task は
# `resume_hint.current_task`（単一フィールド）で帰属を決められない（障壁 B2/B3）。
# 代わりに、書込先 FILE や実行 CWD の**パス**から、それが属する worktree のタスクを
# 一意に逆引きする（design §4.3）。worktree は worktree.sh が常に
# `$ROOT/.claude/worktrees/<task>` に作るため、パスのセグメントが task キーと一致する。
#
# `_` 始まりのため pre-task.sh の dispatcher（`case _*) continue`）はチェックとして起動せず、
# R2/R3/R4 が source して関数を使う。
#
# 依存変数: ROOT（呼び出し元が設定済み）、STATE_FILE（task_status/task_field で使用）。

# パスが属する worktree のタスク名を標準出力へ返す。該当しなければ空＋非ゼロ。
# 相対パスは ROOT 基準で解決する（フックの CWD に依存しない）。
task_from_path() {
  local p="$1"
  [ -n "$p" ] || return 1
  local abs root_real rel
  case "$p" in
    /*) abs="$p" ;;
    *)  abs="${ROOT:-.}/$p" ;;
  esac
  abs=$(realpath -m "$abs" 2>/dev/null || echo "$abs")
  root_real=$(realpath -m "${ROOT:-.}" 2>/dev/null || echo "${ROOT:-.}")
  case "$abs" in
    "$root_real"/.claude/worktrees/*)
      rel="${abs#"$root_real"/.claude/worktrees/}"
      rel="${rel%%/*}"            # 最初のセグメント = task キー
      rel="${rel%$'\r'}"          # Windows jq 由来の CRLF を除去
      [ -n "$rel" ] || return 1
      printf '%s\n' "$rel"
      return 0
      ;;
  esac
  return 1
}

# FILE→CWD の順でタスクを引く。ファイル書込は FILE で、テスト実行など書込先の無い
# コマンドは CWD（=担当 worktree）で帰属する。どちらでも引けなければ空＋非ゼロ。
task_from_file_or_cwd() {
  local file="$1" cwd="$2" t
  if t=$(task_from_path "$file"); then printf '%s\n' "$t"; return 0; fi
  if t=$(task_from_path "$cwd");  then printf '%s\n' "$t"; return 0; fi
  return 1
}

# tasks[<task>].<field> を引く（既定値つき）。
# PT3: タスクローカル状態（sprint/tasks/<task>.status.json）を優先し、無ければ state.json。
# これで failure_count / tdd_phase 等の頻繁更新フィールドを per-task ファイルから直接・即時に
# 読める（reduce 待ちのスタつき無し）。status 等タスクローカルに無いフィールドは state.json へ縮退。
task_field() {
  local t="$1" field="$2" def="${3:-}"
  local lf="${ROOT:-.}/sprint/tasks/$t.status.json" v
  if [ -f "$lf" ]; then
    v=$(jq -r --arg f "$field" '(.[$f]) // empty' "$lf" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  jq -r --arg t "$t" --arg f "$field" --arg d "$def" \
    '(.tasks[$t][$f]) // $d' "$STATE_FILE" 2>/dev/null || printf '%s' "$def"
}

# tasks[<task>].status を引く（未定義は空文字）。
task_status() { task_field "$1" status ""; }
