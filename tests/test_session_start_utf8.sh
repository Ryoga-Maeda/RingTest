#!/usr/bin/env bash
# tests/test_session_start_utf8.sh
# session-start.sh のトランケーションが、マルチバイト境界で切れても
# 常に妥当な UTF-8 を出力することを検証する（python3 経路／フォールバック経路の両方）。

set -euo pipefail

PASS=0
FAIL=0

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

SPRINT_DIR="$TMPDIR_TEST/sprint"
HOOKS_DIR="$TMPDIR_TEST/.claude/sprint/hooks"
mkdir -p "$SPRINT_DIR" "$HOOKS_DIR" "$TMPDIR_TEST/.claude/sprint"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "$SCRIPT_DIR/.claude/sprint/hooks/_guard.sh" "$HOOKS_DIR/_guard.sh"
cp "$SCRIPT_DIR/.claude/sprint/hooks/session-start.sh" "$HOOKS_DIR/session-start.sh"
# §11.2 R-1: v1 RULES.md → V2 L1 フレームワークヘッダに切替
mkdir -p "$TMPDIR_TEST/.claude/agents/_prefix"
[ -f "$SCRIPT_DIR/.claude/agents/_prefix/L1-framework-header.md" ] && \
  cp "$SCRIPT_DIR/.claude/agents/_prefix/L1-framework-header.md" \
     "$TMPDIR_TEST/.claude/agents/_prefix/L1-framework-header.md"

# next_action を多数の日本語（3バイト文字）で埋め、どのバイト位置で切っても
# マルチバイト境界を割りうる状況を作る。
LONG_JP=""
for _ in $(seq 1 200); do LONG_JP="${LONG_JP}あいうえお日本語テスト"; done

cat > "$SPRINT_DIR/state.json" << EOF
{
  "sprint_id": "sprint-test",
  "phase": "EXECUTE",
  "run_state": "RUNNING",
  "contract": {"agreed": true},
  "tasks": {},
  "resilience": {"consecutive_tool_failures": 0, "persist_failed": false, "persist_failed_branches": []},
  "resume_hint": {
    "current_task": "task-01",
    "read_first": ["sprint/checkpoint.md"],
    "next_action": "$LONG_JP"
  },
  "escalations_active": []
}
EOF

# UTF-8 として妥当か検証するヘルパ（python3 を最優先・iconv フォールバック）。
is_valid_utf8() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys; sys.stdin.buffer.read().decode('utf-8')" 2>/dev/null
  else
    iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
  fi
}

# --- ケース1: 通常経路（python3 あり）でマルチバイト境界をまたいで切っても妥当な UTF-8 ---
echo "--- テスト: python3 経路で切り詰めても妥当な UTF-8 ---"
for CAP in 50 51 52 53 100 101 250; do
  OUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="$CAP" \
    bash "$HOOKS_DIR/session-start.sh" 2>/dev/null || true)
  if printf '%s' "$OUT" | is_valid_utf8; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: cap=$CAP で不正 UTF-8 が出力された"
    FAIL=$((FAIL + 1))
  fi
done
[ "$FAIL" -eq 0 ] && echo "PASS: python3 経路は全 cap で妥当な UTF-8"

# --- ケース2: フォールバック経路（python3 を失敗させる）でも妥当な UTF-8 ---
echo "--- テスト: フォールバック経路でも妥当な UTF-8 ---"
FAKE_BIN="$TMPDIR_TEST/fakebin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/python3"
chmod +x "$FAKE_BIN/python3"
FB_FAIL=0
for CAP in 50 51 52 53 100 250; do
  OUT=$(PATH="$FAKE_BIN:$PATH" CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="$CAP" \
    bash "$HOOKS_DIR/session-start.sh" 2>/dev/null || true)
  # 出力がキャップ以内であること（バイト数）
  BYTES=$(printf '%s' "$OUT" | wc -c | tr -d ' ')
  if [ "$BYTES" -gt "$CAP" ]; then
    echo "FAIL(fallback): cap=$CAP を超過（$BYTES bytes）"
    FB_FAIL=$((FB_FAIL + 1)); FAIL=$((FAIL + 1)); continue
  fi
  if printf '%s' "$OUT" | is_valid_utf8; then
    PASS=$((PASS + 1))
  else
    echo "FAIL(fallback): cap=$CAP で不正 UTF-8 が出力された"
    FB_FAIL=$((FB_FAIL + 1)); FAIL=$((FAIL + 1))
  fi
done
[ "$FB_FAIL" -eq 0 ] && echo "PASS: フォールバック経路も全 cap で妥当な UTF-8 かつキャップ以内"

echo ""
echo "================================"
echo "結果: PASS=$PASS, FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
