#!/usr/bin/env bash
# tests/test_subagent_orphan_detection.sh — on-stop.sh からの heartbeat T1 検査連携
#
# 目的:
#   Stop フック (.claude/sprint/hooks/on-stop.sh) が永続化経路で
#   scripts/check-heartbeats.sh を best-effort 駆動し、stale な heartbeat を
#   subagent_health.<agent>.t1_timeout_at として記録できるかを検証する。
#
#   A. 進行中フェーズ (phase=EXECUTE) では check-heartbeats.sh が走り、
#      60 分前 started_at の worker が quarantine 化される
#   B. phase=CLARIFY では should_persist=0 経路に入り、永続化フローごと skip され、
#      heartbeat 検査も走らない（subagent_health は空のまま）
#   C. scripts/check-heartbeats.sh が不在でも on-stop.sh は exit 0
#      （best-effort: 失敗しても保全フローを継続）
#
# 構成:
#   ・mktemp -d で擬似 ROOT を作る
#   ・.claude を丸ごとコピーして source 連鎖を $ROOT 配下で解決させる
#   ・scripts/ もコピー（A/B はコピーする、C はコピーしない）
#   ・.claude/worktrees は作らない → on-stop.sh の worktree ループはスキップされる
#   ・state.json には run_state=RUNNING、v2_active=true を必ず含める（_guard.sh 通過用）

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

ON_STOP="$REPO_ROOT/.claude/sprint/hooks/on-stop.sh"
CHECK="$REPO_ROOT/scripts/check-heartbeats.sh"

[ -f "$ON_STOP" ] || { echo "FAIL: on-stop.sh が存在しない"; exit 1; }
[ -x "$CHECK" ] || { echo "FAIL: check-heartbeats.sh が実行可能でない"; exit 1; }

pass=0
fail=0

# 擬似 ROOT を作るヘルパ。phase と stale worker の有無を指定する。
# with_scripts=1 なら scripts/ を丸ごとコピー、0 ならコピーしない（C シナリオ用）。
make_root() {
  local phase="$1"
  local with_scripts="$2"
  local d
  d=$(mktemp -d)
  cp -r "$REPO_ROOT/.claude" "$d/"
  if [ "$with_scripts" = "1" ]; then
    cp -r "$REPO_ROOT/scripts" "$d/"
  fi
  mkdir -p "$d/sprint"

  # 60 分前 (3600000 ms 前) の started_at をシード。T1=30 分既定を確実に超える。
  local old_started
  old_started=$(( ($(date +%s%N) / 1000000) - 3600000 ))

  cat > "$d/sprint/state.json" <<EOF
{
  "run_state": "RUNNING",
  "v2_active": true,
  "phase": "${phase}",
  "sprint_id": "sprint-test",
  "resume_hint": { "current_task": "none", "next_action": "test", "read_first": ["sprint/state.json"] },
  "subagent_heartbeats": {
    "worker": { "started_at": ${old_started} }
  },
  "subagent_health": {},
  "tasks": {},
  "resilience": {}
}
EOF
  printf '%s\n' "$d"
}

# ------- シナリオ A: phase=EXECUTE なら stale heartbeat が quarantine 化 -------
echo "=== シナリオ A: phase=EXECUTE で stale heartbeat が T1 検知される ==="
A_ROOT=$(make_root EXECUTE 1)
# on-stop.sh は内部で control-plane commit を試みるが、git remote が無くても落ちない設計。
# stderr は冗長なので捨てる。
echo '{}' | CLAUDE_PROJECT_DIR="$A_ROOT" bash "$ON_STOP" >/dev/null 2>&1 || true

A_T1=$(jq -r '.subagent_health.worker.t1_timeout_at // 0' "$A_ROOT/sprint/state.json")
if [ "$A_T1" -gt "0" ] 2>/dev/null; then
  pass=$((pass+1)); echo "  PASS: subagent_health.worker.t1_timeout_at に数値が記録された (=$A_T1)"
else
  fail=$((fail+1)); echo "  FAIL: t1_timeout_at が記録されていない (got='$A_T1')"
fi

# ------- シナリオ B: phase=CLARIFY では永続化が skip され、heartbeat 検査も走らない -------
echo "=== シナリオ B: phase=CLARIFY では subagent_health は空のまま ==="
B_ROOT=$(make_root CLARIFY 1)
echo '{}' | CLAUDE_PROJECT_DIR="$B_ROOT" bash "$ON_STOP" >/dev/null 2>&1 || true

# subagent_health.worker が存在しない（= 空）ことを確認。
B_HAS=$(jq -r '.subagent_health | has("worker")' "$B_ROOT/sprint/state.json")
if [ "$B_HAS" = "false" ]; then
  pass=$((pass+1)); echo "  PASS: phase=CLARIFY では subagent_health は空のまま（should_persist=0 経路）"
else
  fail=$((fail+1)); echo "  FAIL: phase=CLARIFY なのに subagent_health.worker が書かれた"
fi

# ------- シナリオ C: scripts/check-heartbeats.sh 不在でも on-stop は exit 0 -------
echo "=== シナリオ C: check-heartbeats.sh 不在でも on-stop.sh は exit 0 ==="
C_ROOT=$(make_root EXECUTE 0)
# scripts/ をコピーしなかったので $C_ROOT/scripts/check-heartbeats.sh は存在しない。
# on-stop.sh の判定 `[ -x ... ]` で false になり best-effort skip するはず。
set +e
echo '{}' | CLAUDE_PROJECT_DIR="$C_ROOT" bash "$ON_STOP" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass=$((pass+1)); echo "  PASS: scripts 不在でも on-stop.sh は exit 0 (rc=$rc)"
else
  fail=$((fail+1)); echo "  FAIL: on-stop.sh が異常終了した (rc=$rc)"
fi

# 後始末
rm -rf "$A_ROOT" "$B_ROOT" "$C_ROOT"

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
