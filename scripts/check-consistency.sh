#!/usr/bin/env bash
# scripts/check-consistency.sh — state.json と git 実体の整合性検証（ARCHITECTURE_RETROSPECTIVE 1-1）
#
# クラウドの ephemeral 性により、state.json は「実装済み」を主張していても、未 push の
# worktree ブランチがコンテナ破棄で消失している場合がある。再開時にこの乖離を検出できないと、
# state を鵜呑みにして VERIFY へ進み Evaluator が必ず FAIL する。
#
# 本スクリプトは各タスクについて以下を検証し、乖離を「警告」として標準出力に列挙する:
#   - status=COMPLETE / merged=true: 成果（merge_commit が HEAD の ancestor、または
#     last_commit/branch が実在）が確認できるか。
#   - status=IN_PROGRESS: 記録された branch（またはその push 済み追跡）が実在するか。
#
# 終了コード: 0 = 乖離なし / 3 = 乖離あり（呼び出し側は警告として扱う）/ 0 = 非アクティブ・前提不足。
# SessionStart / cloud-kickoff から best-effort で呼ぶ（失敗してもセッションは継続）。
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$ROOT/sprint/state.json"

# PT3: --heal でタスクローカル状態（sprint/tasks/<id>.status.json）も降格するため。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_state.sh" 2>/dev/null || true

[ -f "$STATE_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq empty "$STATE_FILE" >/dev/null 2>&1 || exit 0
git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 || exit 0

# コミットが実在するか（オブジェクトとして取得できるか）。
commit_exists() { [ -n "$1" ] && git -C "$ROOT" cat-file -e "${1}^{commit}" 2>/dev/null; }
# コミットが HEAD の ancestor か（= 既に取り込み済み）。
is_ancestor() { [ -n "$1" ] && git -C "$ROOT" merge-base --is-ancestor "$1" HEAD 2>/dev/null; }
# ブランチがローカル or リモート追跡として実在するか。
branch_exists() {
  [ -n "$1" ] || return 1
  git -C "$ROOT" rev-parse --verify "$1" >/dev/null 2>&1 && return 0
  git -C "$ROOT" rev-parse --verify "origin/$1" >/dev/null 2>&1 && return 0
  return 1
}

WARNINGS=()
HEAL_DEMOTE=()

# IH-W9: 整合性乖離の自動降格（オプトイン）。--heal 引数または SPRINT_CONSISTENCY_HEAL=1 で有効。
# 既定は警告のみ（破壊的変更をしない）。session-start からは警告注入のみ継続し、--heal は
# Orchestrator/明示運用で使う（hardening §5.3.1 / W9）。
HEAL="${SPRINT_CONSISTENCY_HEAL:-0}"
for _arg in "$@"; do
  case "$_arg" in --heal) HEAL=1 ;; esac
done

# タスクキーを1行ずつ取得し、各フィールドは個別 jq で読む。
# （@tsv + IFS=tab は空フィールドが畳まれて列ズレするため使わない）
TASK_KEYS=$(jq -r '.tasks // {} | keys[]?' "$STATE_FILE" 2>/dev/null)
field() { jq -r --arg t "$1" --arg f "$2" '.tasks[$t][$f] // ""' "$STATE_FILE" 2>/dev/null; }

while IFS= read -r task; do
  [ -n "$task" ] || continue
  status=$(field "$task" status)
  branch=$(field "$task" branch)
  merged=$(jq -r --arg t "$task" '.tasks[$t].merged // false | tostring' "$STATE_FILE" 2>/dev/null)
  last_commit=$(field "$task" last_commit)
  merge_commit=$(field "$task" merge_commit)
  case "$status" in
    COMPLETE)
      present="no"
      if [ "$merged" = "true" ]; then
        # マージ済み主張 → merge_commit が ancestor、または成果が ancestor として残るか。
        if is_ancestor "$merge_commit" || is_ancestor "$last_commit" || is_ancestor "$branch"; then
          present="yes"
        elif branch_exists "$branch" || commit_exists "$last_commit"; then
          present="yes"   # 未取り込みだが成果は実在（INTEGRATE 待ち相当）
        fi
        [ "$present" = "no" ] && WARNINGS+=("task '$task': merged=true だが成果（merge_commit/last_commit/branch=$branch）が HEAD に見当たらず、ブランチ/コミットも実在しない（喪失の可能性）。")
      else
        # finish 済み（COMPLETE・未マージ）→ branch か last_commit が実在すべき。
        if branch_exists "$branch" || commit_exists "$last_commit" || is_ancestor "$branch" || is_ancestor "$last_commit"; then
          present="yes"
        fi
        if [ "$present" = "no" ]; then
          WARNINGS+=("task '$task': status=COMPLETE（未マージ）だが branch=$branch も last_commit も実在しない（未 push のままコンテナ破棄で喪失の可能性）。INTEGRATE で再マージ不能。")
          # IH-W9: 未マージ COMPLETE の成果喪失は自動降格対象（--heal 時）。merged=true の喪失は対象外。
          [ "$HEAL" = "1" ] && HEAL_DEMOTE+=("$task")
        fi
      fi
      # 成果物の機械照合（narou-reader feedback A / §3 P1）: 成果（branch/commit）が実在しても、
      # タスク定義で宣言した produces パスが成果 ref に無ければ「state は COMPLETE だが成果物が無い」
      # 乖離である。branch/commit の実在チェックだけでは「主張コードの実在」までは保証できないため、
      # produces[] が定義されているタスクに限り、各パスの実在を成果 ref に対して機械照合する。
      if [ "$present" = "yes" ]; then
        produces=$(jq -r --arg t "$task" '.tasks[$t].produces // [] | .[]?' "$STATE_FILE" 2>/dev/null)
        if [ -n "$produces" ]; then
          # 照合 ref を決める: HEAD に取り込み済みなら HEAD、未取り込みなら branch（ローカル→origin）
          # →last_commit の順に解決する。いずれも解決できなければ照合をスキップ（誤検知を出さない）。
          ref=""
          if is_ancestor "$merge_commit" || is_ancestor "$last_commit" || is_ancestor "$branch"; then
            ref="HEAD"
          elif [ -n "$branch" ] && git -C "$ROOT" rev-parse --verify "$branch" >/dev/null 2>&1; then
            ref="$branch"
          elif [ -n "$branch" ] && git -C "$ROOT" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
            ref="origin/$branch"
          elif commit_exists "$last_commit"; then
            ref="$last_commit"
          fi
          if [ -n "$ref" ]; then
            while IFS= read -r p; do
              [ -n "$p" ] || continue
              if ! git -C "$ROOT" cat-file -e "$ref:$p" 2>/dev/null; then
                WARNINGS+=("task '$task': status=COMPLETE だが宣言した成果物 '$p' が成果 ref ($ref) に存在しない（produces 照合: state は完了主張だが成果物が無い）。")
              fi
            done <<< "$produces"
          fi
        fi
      fi
      ;;
    IN_PROGRESS)
      if [ -n "$branch" ] && [ "$branch" != "null" ]; then
        if ! branch_exists "$branch"; then
          WARNINGS+=("task '$task': status=IN_PROGRESS で branch=$branch が記録されているが、ローカルにも origin/ にも存在しない（worktree 喪失の可能性）。")
        fi
      fi
      ;;
  esac
done <<< "$TASK_KEYS"

# IH-W9: --heal で COMPLETE 未マージの喪失タスクを IN_PROGRESS/RED へ自動降格する（原子的 tmp→mv）。
# false COMPLETE のまま VERIFY/INTEGRATE へ進ませず、EXECUTE で正規に再実装させる。merged=true の
# 成果喪失は破壊回避のため自動降格せず、警告（エスカレーション）に委ねる。
HEALED=()
if [ "$HEAL" = "1" ] && [ "${#HEAL_DEMOTE[@]}" -gt 0 ]; then
  DEMOTE_JSON=$(printf '%s\n' "${HEAL_DEMOTE[@]}" | jq -R . | jq -s .)
  if jq --argjson ks "$DEMOTE_JSON" '
        reduce $ks[] as $k (.;
          .tasks[$k].status = "IN_PROGRESS"
          | .tasks[$k].tdd_phase = "RED"
          | .tasks[$k].merged = false)
      ' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null; then
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    HEALED=("${HEAL_DEMOTE[@]}")
    # PT3: タスクローカル状態も RED/0 へ降格（state.json だけでは R3/R4 が古い値を読む）。
    if command -v update_task_status >/dev/null 2>&1; then
      for _t in "${HEAL_DEMOTE[@]}"; do
        update_task_status "$_t" '.tdd_phase = "RED" | .failure_count = 0' || true
      done
    fi
  else
    rm -f "$STATE_FILE.tmp"
  fi
fi

# FR-3: フック生存カナリア検査。run_state がアクティブ（作業中=RUNNING）なのに hook_heartbeat が
# 一定時間更新されていなければ、フックが無音で死んでいる（fail-open）疑い → fail-closed 警告。
# 終端（COMPLETE/ABORTED）・非アクティブ（OFF）は heartbeat が止まって当然なので検査しない。
RUN_STATE_HB=$(jq -r '.run_state // "OFF"' "$STATE_FILE" 2>/dev/null || echo "OFF")
case "$RUN_STATE_HB" in
  RUNNING)
    HEARTBEAT=$(jq -r '.hook_heartbeat // ""' "$STATE_FILE" 2>/dev/null || echo "")
    HEARTBEAT_MAX_AGE="${SPRINT_HEARTBEAT_MAX_AGE:-1800}"   # 既定30分
    if [ -z "$HEARTBEAT" ]; then
      WARNINGS+=("hook_heartbeat 未記録: run_state=$RUN_STATE_HB（アクティブ）なのにフック生存マーカーが無い。フック未登録/無効化の疑い → fail-closed（作業前にフック有効性を確認）。")
    else
      now_epoch=$(date -u +%s 2>/dev/null || echo 0)
      hb_epoch=$(date -u -d "$HEARTBEAT" +%s 2>/dev/null || \
                 date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$HEARTBEAT" +%s 2>/dev/null || echo 0)
      if [ "$hb_epoch" -gt 0 ] && [ "$((now_epoch - hb_epoch))" -gt "$HEARTBEAT_MAX_AGE" ]; then
        WARNINGS+=("hook_heartbeat が古い（最終 $HEARTBEAT・${HEARTBEAT_MAX_AGE}秒超）: run_state=$RUN_STATE_HB なのにフックが更新していない＝フック死亡の疑い → fail-closed（作業停止して Human 確認）。")
      fi
    fi
    ;;
esac

if [ "${#WARNINGS[@]}" -eq 0 ]; then
  echo "状態整合性: OK（state.json と git 実体に乖離なし）"
  exit 0
fi

echo "## ⚠ 状態整合性の警告（state.json と git 実体の乖離）"
echo ""
for w in "${WARNINGS[@]}"; do
  echo "- $w"
done
echo ""
if [ "${#HEALED[@]}" -gt 0 ]; then
  echo "### 自動降格（IH-W9 / --heal）"
  echo ""
  for h in "${HEALED[@]}"; do
    echo "- task '$h' を status=IN_PROGRESS / tdd_phase=RED へ降格しました（喪失成果を EXECUTE で再実装）。"
  done
  echo ""
fi
echo "→ state を鵜呑みにせず、git log / git branch -a / 成果物の実在を突き合わせてから再開してください。"
exit 3
