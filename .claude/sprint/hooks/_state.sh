#!/usr/bin/env bash
# .claude/sprint/hooks/_state.sh — sprint/state.json への原子的・排他的更新の単一正準実装（PT0-1）
#
# 並列実行（複数サブエージェントのフック）が共有 state.json を同時更新するとき、
# read-modify-write のロストアップデート（last-writer-wins）を flock で消す（design §4.2 Phase A / B1）。
# 各 caller が個別に持っていた update_state（jq … > tmp && mv）を本ファイルへ集約し、シグネチャを統一する。
#
# 排他の段階的縮退（fail-open ではなく「ロック無しでも壊れた JSON を残さない」）:
#   1. flock（util-linux）が使えればファイルロックで直列化（既定）。
#   2. flock 非対応環境（macOS 既定・一部 git-bash）は mkdir スピンロックへフォールバック。
#   3. いずれも不能でも mv は原子的なので、半端な JSON を残さない（jq 失敗時は tmp を破棄）。
# テスト用に SPRINT_STATE_NO_FLOCK=1 で flock 経路を無効化しフォールバックを検証できる。
#
# 依存変数: STATE_FILE（呼び出し元が設定済みであること）。
# シグネチャ（統一）:
#   update_state <jq-filter> [jq-args...]   # filter 先頭。内部で jq <args> <filter> を実行
#   with_state_lock <cmd> [args...]         # 任意コマンドを排他下で実行

# 二重 source ガード（複数フックが source しても再定義しない）。
if [ -z "${__SPRINT_STATE_SH_LOADED:-}" ]; then
__SPRINT_STATE_SH_LOADED=1

# lock ファイルパス（STATE_FILE と同階層。.gitignore 済み＝PT0-3）。
__sprint_lock_path() { printf '%s\n' "${STATE_FILE:?STATE_FILE 未設定}.lock"; }

# 指定ロックファイル下で任意コマンドを実行する汎用ロック。flock 優先・mkdir フォールバック。
# 戻り値は実行したコマンドの終了コード。
with_lock() {
  local lock="$1"; shift
  if [ "${SPRINT_STATE_NO_FLOCK:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
    # サブシェルで fd 9 を lock に開き flock。サブシェル終了で fd が閉じロック解放。
    # flock 取得に失敗しても（NFS 等の異常）処理は続行する（mv の原子性は保たれる）。
    (
      flock 9 2>/dev/null || true
      "$@"
    ) 9>"$lock"
  else
    # フォールバック: mkdir スピンロック（ディレクトリ作成は原子的）。
    local lockdir="${lock}.d" i=0 rc=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      i=$((i + 1)); [ "$i" -ge 100 ] && break
      sleep 0.05 2>/dev/null || sleep 1
    done
    "$@" || rc=$?
    rmdir "$lockdir" 2>/dev/null || true
    return "$rc"
  fi
}

# 排他ロック下で state.json を更新する（共有ロック＝STATE_FILE.lock）。
with_state_lock() {
  local lock; lock="$(__sprint_lock_path)" || return 1
  with_lock "$lock" "$@"
}

# 排他ロック下で state.json を更新する内部実装。jq フィルタを先頭で受ける。
# jq 失敗時は tmp を残さず元ファイルを保つ（壊れた JSON を作らない）。
__sprint_state_apply() {
  local filter="$1"; shift
  local tmp="${STATE_FILE}.tmp"
  if jq "$@" "$filter" "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

# state.json を排他・原子的に更新する正準実装。
# 例: update_state '.tasks[$t].status = "COMPLETE"' --arg t "$TASK"
update_state() {
  local filter="$1"; shift
  with_state_lock __sprint_state_apply "$filter" "$@"
}

# ===== PT3: タスクローカル状態（sprint/tasks/<id>.status.json）=====
# 並列実行で頻繁に書かれる per-task フィールド（failure_count / tdd_phase / resume_note）を、
# 共有 state.json から「タスクごとの別ファイル」へ分離する。各タスクが専用ファイルを持つため、
# Worker / post-task が同一フィールドを奪い合う構造（B1 のロック競合）が消える（design §4.2 Phase B）。
# status・worktree 等の構造フィールドは boundary 単一ライター（worktree.sh/integrator agent）が
# 共有 state.json に書くため、ここでは扱わない（読み手＝plan-waves/integrator の互換を保つ）。

# タスクローカル状態ファイルのパス。
sprint_task_status_file() { printf '%s\n' "${ROOT:?ROOT 未設定}/sprint/tasks/$1.status.json"; }

# タスクローカル状態を排他・原子的に更新する（per-task ロック＝タスク間で非競合）。
# 例: update_task_status <task> '.failure_count = ((.failure_count // 0) + 1)'
__sprint_task_apply() {
  local f="$1" filter="$2"; shift 2
  local tmp="$f.tmp"
  if jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}
update_task_status() {
  local task="$1" filter="$2"; shift 2
  local f; f="$(sprint_task_status_file "$task")" || return 1
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  # ファイル不在/空（新規タスク or コンテナ再 clone 後）は、state.json の reduce 済みミラー
  # （failure_count/tdd_phase/resume_note）から再シードする。status.json は gitignore 済みの
  # 揮発スクラッチで、耐久値の真実源は state.json（reduce_task_status が集約し制御面で保全する）。
  # これにより status.json を git 追跡しなくても failure_count 等が再 clone を越えて生き残る。
  # STATE_FILE 不在/ミラー空なら従来どおり {} で初期化する（挙動互換）。
  if [ ! -s "$f" ]; then
    local seed='{}'
    if [ -n "${STATE_FILE:-}" ] && [ -f "${STATE_FILE:-}" ]; then
      seed=$(jq -c --arg t "$task" \
        '.tasks[$t] // {} | {failure_count, tdd_phase, resume_note} | with_entries(select(.value != null))' \
        "$STATE_FILE" 2>/dev/null || echo '{}')
    fi
    [ -n "$seed" ] && [ "$seed" != "null" ] || seed='{}'
    printf '%s\n' "$seed" > "$f"
  fi
  with_lock "$f.lock" __sprint_task_apply "$f" "$filter" "$@"
}

# タスクローカル状態を共有 state.json へ集約（reduce）する。表示・スナップショット用。
# sprint/tasks/<id>.status.json の failure_count/tdd_phase/resume_note を state.json.tasks[<id>] へ反映。
# 冪等・原子的（state ロック）。読み取り専用の利便性であり、hot-path の真実はタスクローカル側。
reduce_task_status() {
  local dir="${ROOT:?ROOT 未設定}/sprint/tasks"
  [ -d "$dir" ] || return 0
  local f task loc
  for f in "$dir"/*.status.json; do
    [ -e "$f" ] || continue
    task="$(basename "$f")"; task="${task%.status.json}"
    loc="$(jq -c . "$f" 2>/dev/null || echo '{}')"
    update_state '
      .tasks[$t] = ((.tasks[$t] // {}) + (
        $loc | {failure_count, tdd_phase, resume_note}
        | with_entries(select(.value != null)) ))' \
      --arg t "$task" --argjson loc "$loc" 2>/dev/null || true
  done
  return 0
}

fi  # __SPRINT_STATE_SH_LOADED
