#!/usr/bin/env bash
# scripts/validate-settings.sh — settings.json の JSON 妥当性とフック登録スキーマを検証（FR-2）
#
# フック設定の破損（不正 JSON・スキーマ不適合）が混入すると、フックが無音で失敗して
# 全ガードレールが消える（fail-open）。これを pre-commit / CI（フック非依存の一次防御）で
# 物理的に止めるための決定論的バリデータ。
#
# 使い方: validate-settings.sh [file ...]
#   引数省略時は既定の2ファイル（.claude/settings.json, .claude/sprint/settings.json）。
#   いずれかが不正 JSON、または hooks 登録が現行スキーマに適合しなければ非0で終了する。
set -uo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

FILES=("$@")
if [ "${#FILES[@]}" -eq 0 ]; then
  FILES=("$ROOT/.claude/settings.json" "$ROOT/.claude/sprint/settings.json")
fi

# hooks 登録スキーマ（現行 Claude Code）:
#   .hooks は object。各 value（イベント: SessionStart/PreToolUse/PostToolUse/Stop 等）は array。
#   各イベント要素は .hooks（array）を持ち、各 hook は type=="command" かつ command が string。
#   matcher は任意（Stop など matcher 無しを許容）が、存在する場合は string（FR-5: string↔array の
#   ドリフトを弾く。matcher を array にする破壊的変更が混入するとマッチ不発でフックが無音化する）。
#   and は短絡評価のため、value が array でないケースでも右辺の all は評価されず安全。
SCHEMA_FILTER='
  (.hooks // {}) as $h
  | ($h | type) == "object"
  and ($h | to_entries | all(
        (.value | type) == "array"
        and (.value | all(
              ((has("matcher")|not) or ((.matcher | type) == "string"))
              and (.hooks | type) == "array"
              and (.hooks | all(
                    (.type == "command") and ((.command | type) == "string")
                  ))
            ))
      ))
'

rc=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  if ! jq empty "$f" >/dev/null 2>&1; then
    echo "settings 検証 NG: $f は不正な JSON です" >&2
    rc=1
    continue
  fi
  if ! jq -e "$SCHEMA_FILTER" "$f" >/dev/null 2>&1; then
    echo "settings 検証 NG: $f の hooks 登録が現行スキーマに適合しません" >&2
    rc=1
  fi
done
exit $rc
