#!/usr/bin/env bash
# scripts/plan-waves.sh — DAG ウェーブ計画（PT2-3 / 柱1・B5）
#
# state.json.tasks の depends_on（依存）と touches（対象ファイル集合）から、
# 並列実行可能なウェーブ列を決定論的に計算して JSON 出力する。Orchestrator はこれを読み、
# 各ウェーブのタスクを「1メッセージで複数 Agent 起動」して並列実行する（design §4.1）。
#
# 規則:
#   - depends_on の入次数0のタスク群を wave 0、以降トポロジカルに wave 1, 2, …（バリア同期）。
#   - 既に COMPLETE / merged の依存は「満たされた」とみなす（再開時も正しく計画できる）。
#   - 同一依存レベル内で touches が重なるタスクは別ウェーブへ送って直列化する（相互汚染回避）。
#   - 計画対象は status が COMPLETE / FAILED でない（=未完）タスク。
#
# 出力: {"waves":[["task-001","task-002"],["task-004"],...]}
#   循環依存・state 不正は非ゼロ終了（fail-closed）。
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$ROOT/sprint/state.json"

command -v jq >/dev/null 2>&1 || { echo "plan-waves: jq が必要です" >&2; exit 2; }
[ -f "$STATE_FILE" ] || { echo "plan-waves: state.json がありません: $STATE_FILE" >&2; exit 2; }
jq empty "$STATE_FILE" >/dev/null 2>&1 || { echo "plan-waves: state.json が不正な JSON です" >&2; exit 2; }

# --- 依存レベリング（Kahn 法・トポロジカル）。出力は [[level0...],[level1...],...] ---
LEVELS_JSON=$(jq -c '
  (.tasks // {}) as $tasks
  | ($tasks | keys) as $all
  | [ $all[] | select(($tasks[.].status // "") as $s
        | $s != "COMPLETE" and $s != "FAILED" and (($tasks[.].merged // false) != true)) ] as $pending
  | [ $all[] | select(($tasks[.].status // "") == "COMPLETE" or ($tasks[.].merged // false) == true) ] as $done
  | { placed: [], remaining: $pending, levels: [] }
  | until((.remaining | length) == 0;
      . as $st
      | ($st.placed + $done) as $sat
      | [ $st.remaining[] as $t
          | select( ($tasks[$t].depends_on // [])
                    | map(select(. as $d | $all | index($d)))
                    | all(. as $d | $sat | index($d) != null) )
          | $t ] as $ready
      | if ($ready | length) == 0 then error("cycle") else . end
      | { placed: ($st.placed + $ready),
          remaining: ($st.remaining - $ready),
          levels: ($st.levels + [ ($ready | sort) ]) })
  | .levels
' "$STATE_FILE" 2>/dev/null) || {
  echo "plan-waves: 依存グラフに循環があります（depends_on を見直してください）" >&2
  exit 3
}

# touches（対象ファイル集合）の取得と重なり判定（プレフィックス対応）。
touches_of() { jq -r --arg t "$1" '(.tasks[$t].touches // [])[]? // empty' "$STATE_FILE" 2>/dev/null; }
norm() { local p="$1"; p="${p%/}"; p="${p%/\*}"; p="${p%/}"; printf '%s' "$p"; }
overlap() {  # $1,$2 = task id。touches がパス・プレフィックスで交われば 0。
  local a b na nb
  while IFS= read -r a; do
    [ -n "$a" ] || continue; na=$(norm "$a")
    while IFS= read -r b; do
      [ -n "$b" ] || continue; nb=$(norm "$b")
      [ "$na" = "$nb" ] && return 0
      case "$nb" in "$na"/*) return 0 ;; esac
      case "$na" in "$nb"/*) return 0 ;; esac
    done < <(touches_of "$2")
  done < <(touches_of "$1")
  return 1
}

# 1レベル内を touches 重なりで貪欲分割し、各サブウェーブを JSON 配列で出力する。
declare -a WAVES=()
emit_subwaves() {
  local -a tasks=("$@")
  local -a sw_join=()   # 各サブウェーブ = 空白連結のタスク列
  local t idx placed m conflict
  for t in "${tasks[@]}"; do
    [ -n "$t" ] || continue
    placed=-1
    for idx in "${!sw_join[@]}"; do
      conflict=0
      for m in ${sw_join[$idx]}; do
        if overlap "$t" "$m"; then conflict=1; break; fi
      done
      if [ "$conflict" -eq 0 ]; then placed="$idx"; break; fi
    done
    if [ "$placed" -ge 0 ]; then
      sw_join[$placed]="${sw_join[$placed]} $t"
    else
      sw_join+=("$t")
    fi
  done
  for idx in "${!sw_join[@]}"; do
    # 空白連結 → JSON 配列
    WAVES+=("$(printf '%s\n' ${sw_join[$idx]} | jq -R . | jq -s -c .)")
  done
}

# 各依存レベルを取り出して分割
NLEVELS=$(printf '%s' "$LEVELS_JSON" | jq 'length')
i=0
while [ "$i" -lt "${NLEVELS:-0}" ]; do
  # レベル i のタスク列（空白区切り）
  read -r -a LEVEL_TASKS <<< "$(printf '%s' "$LEVELS_JSON" | jq -r --argjson i "$i" '.[$i] | join(" ")')"
  emit_subwaves "${LEVEL_TASKS[@]}"
  i=$((i + 1))
done

# 収集したサブウェーブ列を {"waves":[...]} に束ねる
if [ "${#WAVES[@]}" -eq 0 ]; then
  echo '{"waves":[]}'
else
  printf '%s\n' "${WAVES[@]}" | jq -s -c '{waves: .}'
fi
