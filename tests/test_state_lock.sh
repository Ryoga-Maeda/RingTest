#!/usr/bin/env bash
# tests/test_state_lock.sh — PT0-1: flock 付き共通 update_state（_state.sh）の単体テスト
# 並行書き込みでロストアップデートが起きないこと・flock 不在フォールバック・原子性を検証する。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_SH="$ROOT_REPO/.claude/sprint/hooks/_state.sh"
PASS=0; FAIL=0
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STATE_FILE="$T/state.json"

# 並行加算ワーカー: 同一 .counter を M 回インクリメントする子プロセスを N 体走らせ、
# ロストアップデートが無ければ最終値は N*M になる。
N=8; M=25; TOTAL=$((N * M))

run_concurrent() {
  local no_flock="$1"
  echo '{"counter":0}' > "$STATE_FILE"
  local p
  for p in $(seq 1 "$N"); do
    (
      # shellcheck disable=SC1090
      SPRINT_STATE_NO_FLOCK="$no_flock" source "$STATE_SH"
      export SPRINT_STATE_NO_FLOCK="$no_flock"
      for _ in $(seq 1 "$M"); do
        update_state '.counter += 1'
      done
    ) &
  done
  wait
  jq -r '.counter' "$STATE_FILE" 2>/dev/null || echo "INVALID"
}

echo "=== test_state_lock.sh (PT0-1) ==="

# 1) flock 経路: 並行 N*M 加算でロストアップデートが起きない
GOT=$(run_concurrent 0)
expect "[flock] 並行加算でロスト無し（counter=$TOTAL）" "$TOTAL" "$GOT"
expect "[flock] 更新後も JSON が妥当" "ok" "$(jq empty "$STATE_FILE" >/dev/null 2>&1 && echo ok || echo broken)"

# 2) flock 不在フォールバック（mkdir スピンロック）でもロスト無し
GOT=$(run_concurrent 1)
expect "[fallback] flock 無効化でもロスト無し（counter=$TOTAL）" "$TOTAL" "$GOT"
expect "[fallback] 更新後も JSON が妥当" "ok" "$(jq empty "$STATE_FILE" >/dev/null 2>&1 && echo ok || echo broken)"

# 3) 単一プロセスの基本挙動（filter 先頭＋jq 引数）が従来どおり
echo '{"tasks":{}}' > "$STATE_FILE"
# shellcheck disable=SC1090
source "$STATE_SH"
update_state '.tasks[$t] = {status:"IN_PROGRESS"}' --arg t "task-01"
expect "[単一] filter 先頭＋--arg で更新できる" "IN_PROGRESS" "$(jq -r '.tasks["task-01"].status' "$STATE_FILE")"
update_state '.tasks[$t].status = "COMPLETE"' --arg t "task-01"
expect "[単一] 既存フィールドを上書きできる" "COMPLETE" "$(jq -r '.tasks["task-01"].status' "$STATE_FILE")"

# 4) jq が失敗（不正フィルタ）しても壊れた JSON を残さない（元ファイル保持）
BEFORE=$(cat "$STATE_FILE")
update_state '.tasks[$t]. = bad syntax' --arg t "task-01" 2>/dev/null || true
expect "[原子性] 不正フィルタで元 JSON が壊れない" "ok" "$(jq empty "$STATE_FILE" >/dev/null 2>&1 && echo ok || echo broken)"
expect "[原子性] 不正フィルタで内容が不変" "$BEFORE" "$(cat "$STATE_FILE")"

# 5) with_state_lock で任意コマンドを排他実行できる
echo '{"v":1}' > "$STATE_FILE"
with_state_lock true
expect "[with_state_lock] 成功コマンドで rc=0" "0" "$?"

# ===== PT3: タスクローカル状態（update_task_status / reduce_task_status）=====
export ROOT="$T"
mkdir -p "$T/sprint/tasks"
echo '{"schema_version":3,"tasks":{"task-01":{"status":"IN_PROGRESS"},"task-02":{"status":"IN_PROGRESS"}}}' > "$STATE_FILE"

# 6) update_task_status はタスクローカルへ書き、state.json を触らない
update_task_status task-01 '.failure_count = ((.failure_count // 0) + 1) | .tdd_phase = "RED"'
expect "[PT3] タスクローカルファイルが作られる" "ok" "$([ -f "$T/sprint/tasks/task-01.status.json" ] && echo ok || echo no)"
expect "[PT3] タスクローカルに failure_count=1" "1" "$(jq -r '.failure_count' "$T/sprint/tasks/task-01.status.json")"
expect "[PT3] state.json は未変更（task-01 に failure_count 無し）" "null" "$(jq -r '.tasks["task-01"].failure_count // "null"' "$STATE_FILE")"

# 7) 別タスクの並行更新は互いに干渉しない（per-task ファイル＝非競合）
worker_task() {
  local task="$1"
  # shellcheck disable=SC1090
  source "$STATE_SH"; export ROOT="$T"
  for _ in $(seq 1 20); do update_task_status "$task" '.failure_count = ((.failure_count // 0) + 1)'; done
}
( worker_task task-01 ) & ( worker_task task-02 ) & wait
expect "[PT3] task-01 の並行加算が正しい（1+20=21）" "21" "$(jq -r '.failure_count' "$T/sprint/tasks/task-01.status.json")"
expect "[PT3] task-02 の並行加算が正しい（20）" "20" "$(jq -r '.failure_count' "$T/sprint/tasks/task-02.status.json")"

# 8) reduce_task_status がタスクローカル → state.json へ集約する
reduce_task_status
expect "[PT3] reduce で state.json task-01.failure_count=21" "21" "$(jq -r '.tasks["task-01"].failure_count' "$STATE_FILE")"
expect "[PT3] reduce で state.json task-01.tdd_phase=RED" "RED" "$(jq -r '.tasks["task-01"].tdd_phase' "$STATE_FILE")"
expect "[PT3] reduce 後も status（構造フィールド）は保持" "IN_PROGRESS" "$(jq -r '.tasks["task-01"].status' "$STATE_FILE")"

# ===== PT3 再シード（gitignore 化＝sprint-9 教訓）: status.json は揮発スクラッチ。 =====
# ファイル不在（再 clone 後相当）では state.json の reduce 済みミラーから耐久値を再シードする。
# 9) state.json ミラーに耐久値があれば、status.json 不在から再シードして加算が継続する
echo '{"schema_version":3,"tasks":{"task-09":{"status":"IN_PROGRESS","failure_count":2,"tdd_phase":"GREEN"}}}' > "$STATE_FILE"
rm -f "$T/sprint/tasks/task-09.status.json"
update_task_status task-09 '.failure_count = ((.failure_count // 0) + 1)'
expect "[PT3再シード] 不在から state.json ミラー(2)を再シードし加算→3" "3" "$(jq -r '.failure_count' "$T/sprint/tasks/task-09.status.json")"
expect "[PT3再シード] tdd_phase もミラーから引き継ぐ(GREEN)" "GREEN" "$(jq -r '.tdd_phase' "$T/sprint/tasks/task-09.status.json")"

# 10) state.json にミラーが無いタスクは {} 初期化と同じ（従来挙動互換）
echo '{"schema_version":3,"tasks":{}}' > "$STATE_FILE"
rm -f "$T/sprint/tasks/task-10.status.json"
update_task_status task-10 '.failure_count = ((.failure_count // 0) + 1)'
expect "[PT3再シード] ミラー無しは {} 初期化と同じ（failure_count=1）" "1" "$(jq -r '.failure_count' "$T/sprint/tasks/task-10.status.json")"

# 11) STATE_FILE 不在でも壊れず {} 初期化へフォールバックする
( export STATE_FILE="$T/does-not-exist.json"; rm -f "$T/sprint/tasks/task-11.status.json"
  update_task_status task-11 '.failure_count = ((.failure_count // 0) + 1)' )
expect "[PT3再シード] STATE_FILE 不在でも failure_count=1" "1" "$(jq -r '.failure_count' "$T/sprint/tasks/task-11.status.json")"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
