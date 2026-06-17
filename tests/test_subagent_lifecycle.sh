#!/usr/bin/env bash
# tests/test_subagent_lifecycle.sh — Wave 1 サブエージェント・ライフサイクル管理の動作確認
#
# 目的:
#   PreToolUse(Task) / PostToolUse(Task) フックが state.json.subagent_heartbeats を
#   起動時に書き・完了時に消す「ハンドシェイク」を正しく成立させているかを検証する。
#   検証対象は次の振る舞い:
#     A. Pre フックで .subagent_heartbeats.<agent>.started_at が epoch ms で書かれる
#     B. Post フックで（契約 PASS 経路でも） .subagent_heartbeats.<agent> が削除される
#     C. v2_active=false の state では Pre フックは silent exit（書き込まない）
#     D. tool_input.subagent_type が空の Post フックは silent exit（削除しない）
#
# 構成:
#   ・mktemp -d で擬似 ROOT を作り、.claude / sprint を丸ごと配置する
#   ・既存リポジトリのフック実体をコピーするため、source 連鎖（_guard.sh / _state.sh /
#     phase-advance.sh）も $ROOT 配下から解決される
#   ・post-tool-use-task.sh は内部で phase-advance.sh を呼ぶが、state.json の必須キーが
#     揃わないと途中で失敗し得る。本テストでは heartbeat 削除が phase-advance より
#     前に行われる契約を見るため、phase-advance の成否は無視する（|| true で握り潰す）

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

PRE_HOOK="$REPO_ROOT/.claude/sprint/hooks/pre-tool-use-task.sh"
POST_HOOK="$REPO_ROOT/.claude/sprint/hooks/post-tool-use-task.sh"

[ -f "$PRE_HOOK" ] || { echo "FAIL: pre-tool-use-task.sh が存在しない"; exit 1; }
[ -f "$POST_HOOK" ] || { echo "FAIL: post-tool-use-task.sh が存在しない"; exit 1; }

pass=0
fail=0

# 擬似 ROOT の準備ヘルパ。v2_active と phase を指定して state.json を初期化する。
make_root() {
  local v2="$1"
  local phase="${2:-EXECUTE}"
  local d
  d=$(mktemp -d)
  # フック / scripts を丸ごとコピー（_guard.sh / _state.sh / phase-advance.sh 等の
  # source 連鎖を $ROOT 配下で解決させるため）。
  cp -r "$REPO_ROOT/.claude" "$d/"
  cp -r "$REPO_ROOT/scripts" "$d/" 2>/dev/null || true
  mkdir -p "$d/sprint"
  cat > "$d/sprint/state.json" <<EOF
{
  "run_state": "RUNNING",
  "v2_active": ${v2},
  "phase": "${phase}",
  "subagent_heartbeats": {},
  "subagent_health": {}
}
EOF
  printf '%s\n' "$d"
}

# ------- シナリオ A: Pre フックで started_at が数値で書かれる -------
echo "=== シナリオ A: Pre フックで started_at 書込 ==="
A_ROOT=$(make_root true)
echo '{"tool_input":{"subagent_type":"worker"}}' \
  | CLAUDE_PROJECT_DIR="$A_ROOT" bash "$PRE_HOOK" || true

A_STARTED=$(jq -r '.subagent_heartbeats.worker.started_at // 0' "$A_ROOT/sprint/state.json")
if [ "$A_STARTED" -gt "0" ] 2>/dev/null; then
  pass=$((pass+1)); echo "  PASS: subagent_heartbeats.worker.started_at が数値で書かれた (=$A_STARTED)"
else
  fail=$((fail+1)); echo "  FAIL: started_at が書かれていない (got='$A_STARTED')"
fi

# ------- シナリオ B: Post フック（契約不在 = PASS 経路）で削除される -------
# シナリオ A のあとの state を引き継ぎ、worker が起動中のところへ Post を打つ。
# contract yaml が存在しない agent では verify が走らず PASS 経路を通り、
# heartbeat 削除 → phase-advance の順で実行される。
# 注意: post-tool-use-task.sh は v2_active 判定で `sprint/state.json` をカレント相対で
# 参照するため、フック起動前に擬似 ROOT へ cd する必要がある。
echo "=== シナリオ B: Post フックで heartbeat 削除（契約不在 PASS 経路） ==="
echo '{"tool_input":{"subagent_type":"worker"},"tool_response":{}}' \
  | ( cd "$A_ROOT" && CLAUDE_PROJECT_DIR="$A_ROOT" bash "$POST_HOOK" ) >/dev/null 2>&1 || true

B_HAS=$(jq -r '.subagent_heartbeats | has("worker")' "$A_ROOT/sprint/state.json")
if [ "$B_HAS" = "false" ]; then
  pass=$((pass+1)); echo "  PASS: subagent_heartbeats.worker が削除された"
else
  fail=$((fail+1)); echo "  FAIL: subagent_heartbeats.worker が残存 (has=$B_HAS)"
fi

# ------- シナリオ C: v2_active=false なら Pre は no-op -------
echo "=== シナリオ C: v2_active=false の Pre は no-op ==="
C_ROOT=$(make_root false)
echo '{"tool_input":{"subagent_type":"worker"}}' \
  | CLAUDE_PROJECT_DIR="$C_ROOT" bash "$PRE_HOOK" || true

C_HAS=$(jq -r '.subagent_heartbeats | has("worker")' "$C_ROOT/sprint/state.json")
if [ "$C_HAS" = "false" ]; then
  pass=$((pass+1)); echo "  PASS: v2_active=false では heartbeat が書かれない"
else
  fail=$((fail+1)); echo "  FAIL: v2_active=false なのに heartbeat が書かれた"
fi

# ------- シナリオ D: subagent_type 空の Post は no-op（削除しない） -------
# 既存の worker heartbeat を残したまま、subagent_type 空の Post を打って維持されることを確認。
echo "=== シナリオ D: subagent_type 空の Post は heartbeat を維持 ==="
D_ROOT=$(make_root true)
# worker の heartbeat を手動で書いておく（Pre フック相当の状態を作る）。
now_ms=$(($(date +%s%N) / 1000000))
tmp_seed="$D_ROOT/sprint/state.json.tmp"
jq --arg t "$now_ms" \
  '.subagent_heartbeats.worker = { started_at: ($t | tonumber) }' \
  "$D_ROOT/sprint/state.json" > "$tmp_seed" && mv "$tmp_seed" "$D_ROOT/sprint/state.json"

# subagent_type を欠いた Post 入力 → agent 識別不能のため何もしないはず。
echo '{"tool_input":{},"tool_response":{}}' \
  | CLAUDE_PROJECT_DIR="$D_ROOT" bash "$POST_HOOK" >/dev/null 2>&1 || true

D_HAS=$(jq -r '.subagent_heartbeats | has("worker")' "$D_ROOT/sprint/state.json")
if [ "$D_HAS" = "true" ]; then
  pass=$((pass+1)); echo "  PASS: subagent_type 空では heartbeat が維持される"
else
  fail=$((fail+1)); echo "  FAIL: subagent_type 空なのに heartbeat が削除された"
fi

# 後始末
rm -rf "$A_ROOT" "$C_ROOT" "$D_ROOT"

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
