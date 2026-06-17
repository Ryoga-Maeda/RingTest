#!/usr/bin/env bash
# tests/test_session_start_parse_recovery.sh
# FR-4 補完（再接地ガード）: session-start.sh が「tool-call parse 失敗直後の自動再開」を検出し、
# 注入の最上段に再接地指示（実体検証から再開せよ）を出すことを検証する。
# 汚染履歴を土台にした自動再開（compact / 新セッション）での作話＝大きなハルシネーションの抑止策。
#
# 検出は2系統:
#   (B) state フラグ .resilience.parse_failure_recent（runner が異常終了時に立てる）→ 一度きりで消費。
#   (A) runner 捕捉ログ SESSION_LOG の末尾に parse 失敗痕跡（compact / 同一セッション経路）。

set -euo pipefail

PASS=0
FAIL=0

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

SPRINT_DIR="$TMPDIR_TEST/sprint"
HOOKS_DIR="$TMPDIR_TEST/.claude/sprint/hooks"
mkdir -p "$SPRINT_DIR" "$HOOKS_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_guard.sh" "$HOOKS_DIR/_guard.sh"
cp "$SCRIPT_DIR/.claude/sprint/hooks/session-start.sh" "$HOOKS_DIR/session-start.sh"

GUARD_MARK="パース失敗からの再開"

make_state() {
  # $1: parse_failure_recent（true/false。既定 false）
  local pfr="${1:-false}"
  cat > "$SPRINT_DIR/state.json" << EOF
{
  "sprint_id": "sprint-test",
  "phase": "EXECUTE",
  "run_state": "RUNNING",
  "contract": {"agreed": true, "agreed_at": null, "iteration": 0, "max_iterations": 15},
  "tasks": {},
  "resilience": {
    "consecutive_tool_failures": 0,
    "persist_failed": false,
    "persist_failed_branches": [],
    "parse_failure_recent": $pfr
  },
  "resume_hint": {
    "current_task": "task-01",
    "read_first": ["sprint/checkpoint.md"],
    "next_action": "task-01 を継続"
  },
  "escalations_active": [],
  "escalations_archived_ref": null
}
EOF
}

run_hook() {
  CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="5000" \
    bash "$HOOKS_DIR/session-start.sh" 2>/dev/null
}

# ---------- テスト1: state フラグ (B) で再接地ガードが出る ----------
echo "--- テスト: parse_failure_recent=true で再接地ガードを注入（経路B） ---"
make_state true
rm -f "$SPRINT_DIR/.session-out.log"
OUTPUT=$(run_hook)
if echo "$OUTPUT" | grep -q "$GUARD_MARK"; then
  echo "PASS: フラグ true で再接地ガードが注入される"
  PASS=$((PASS + 1))
else
  echo "FAIL: フラグ true なのに再接地ガードが出ない"
  FAIL=$((FAIL + 1))
fi

# ---------- テスト2: フラグ (B) は一度きりで消費（クリア）される ----------
echo "--- テスト: parse_failure_recent はガード注入後に false へクリアされる ---"
CLEARED=$(jq -r '.resilience.parse_failure_recent' "$SPRINT_DIR/state.json" 2>/dev/null || echo "ERROR")
if [ "$CLEARED" = "false" ]; then
  echo "PASS: 注入後にフラグが false へクリアされた（一度きり消費）"
  PASS=$((PASS + 1))
else
  echo "FAIL: フラグがクリアされていない（actual=$CLEARED）"
  FAIL=$((FAIL + 1))
fi

# ---------- テスト3: 再接地ガードは最上段（状態サマリーより前）に置かれる ----------
echo "--- テスト: 再接地ガードが状態サマリーより前に出力される ---"
make_state true
rm -f "$SPRINT_DIR/.session-out.log"
OUTPUT=$(run_hook)
GUARD_LINE=$(echo "$OUTPUT" | grep -n "$GUARD_MARK" | head -1 | cut -d: -f1)
SUMMARY_LINE=$(echo "$OUTPUT" | grep -n "スプリント状態サマリー" | head -1 | cut -d: -f1)
if [ -n "$GUARD_LINE" ] && [ -n "$SUMMARY_LINE" ] && [ "$GUARD_LINE" -lt "$SUMMARY_LINE" ]; then
  echo "PASS: 再接地ガードが状態サマリーより前（行 $GUARD_LINE < $SUMMARY_LINE）"
  PASS=$((PASS + 1))
else
  echo "FAIL: ガード位置が想定外（guard=$GUARD_LINE summary=$SUMMARY_LINE）"
  FAIL=$((FAIL + 1))
fi

# ---------- テスト4: SESSION_LOG 末尾の parse 失敗痕跡 (A) で再接地ガードが出る ----------
echo "--- テスト: SESSION_LOG 末尾の parse 失敗痕跡で再接地ガード（経路A・compact） ---"
make_state false   # フラグは false。SESSION_LOG 痕跡だけで検出できることを確認
cat > "$SPRINT_DIR/.session-out.log" << 'EOF'
... 通常の出力 ...
The model's tool call could not be parsed (retry also failed).
... 続き ...
EOF
OUTPUT=$(run_hook)
if echo "$OUTPUT" | grep -q "$GUARD_MARK"; then
  echo "PASS: SESSION_LOG 痕跡（経路A）で再接地ガードが注入される"
  PASS=$((PASS + 1))
else
  echo "FAIL: SESSION_LOG に痕跡があるのに再接地ガードが出ない"
  FAIL=$((FAIL + 1))
fi

# ---------- テスト5: 痕跡なし（フラグ false・ログなし）では再接地ガードを出さない（偽陽性防止） ----------
echo "--- テスト: parse 失敗痕跡が無ければ再接地ガードを出さない（偽陽性防止） ---"
make_state false
rm -f "$SPRINT_DIR/.session-out.log"
OUTPUT=$(run_hook)
if echo "$OUTPUT" | grep -q "$GUARD_MARK"; then
  echo "FAIL: 痕跡が無いのに再接地ガードが出た（偽陽性）"
  FAIL=$((FAIL + 1))
else
  echo "PASS: 痕跡が無ければ再接地ガードを出さない"
  PASS=$((PASS + 1))
fi

# ---------- テスト6: 痕跡が末尾走査範囲外なら出さない（自然減衰の確認） ----------
echo "--- テスト: parse 失敗痕跡が末尾走査範囲外なら出さない ---"
make_state false
{
  echo "The model's tool call could not be parsed (retry also failed)."
  for _ in $(seq 1 120); do echo "通常の進捗ログ行"; done
} > "$SPRINT_DIR/.session-out.log"
OUTPUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="5000" \
  SPRINT_POISON_SCAN_LINES="80" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
if echo "$OUTPUT" | grep -q "$GUARD_MARK"; then
  echo "FAIL: 痕跡が走査範囲外（直近80行外）なのにガードが出た"
  FAIL=$((FAIL + 1))
else
  echo "PASS: 痕跡が走査範囲外なら自然にガードが止む"
  PASS=$((PASS + 1))
fi

# ---------- テスト7: 再接地ガードが checkpoint.md からの再水和手順を明示する（②強化） ----------
echo "--- テスト: 再接地ガードが checkpoint.md 再水和手順を含む（②強化） ---"
make_state true
rm -f "$SPRINT_DIR/.session-out.log"
OUTPUT=$(run_hook)
if echo "$OUTPUT" | grep -q "checkpoint.md" && echo "$OUTPUT" | grep -q "再水和"; then
  echo "PASS: 再接地ガードが checkpoint.md 再水和手順を明示する"
  PASS=$((PASS + 1))
else
  echo "FAIL: 再接地ガードに checkpoint.md 再水和手順が無い"
  FAIL=$((FAIL + 1))
fi

# 結果サマリー
echo ""
echo "================================"
echo "結果: PASS=$PASS, FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
