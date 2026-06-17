#!/usr/bin/env bash
# tests/test_session_start_cap.sh
# P1-4 session-start.sh のテスト
# バイト数キャップ、resume_hint パスの出力、全文ダンプしないことを検証

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

# §11.2 R-1: v1 RULES.md → V2 L1 フレームワークヘッダに切替
if [ -f "$SCRIPT_DIR/.claude/agents/_prefix/L1-framework-header.md" ]; then
  mkdir -p "$TMPDIR_TEST/.claude/agents/_prefix"
  cp "$SCRIPT_DIR/.claude/agents/_prefix/L1-framework-header.md" \
     "$TMPDIR_TEST/.claude/agents/_prefix/L1-framework-header.md"
fi

make_state() {
  local next_action="${1:-state.json を確認して継続}"
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
    "persist_failed_branches": []
  },
  "resume_hint": {
    "current_task": "task-01",
    "read_first": ["sprint/checkpoint.md", "sprint/SPRINT.md"],
    "next_action": "$next_action"
  },
  "escalations_active": [],
  "escalations_archived_ref": null
}
EOF
}

# テストケース1: 非アクティブ状態では no-op（出力なし）
echo "--- テスト: 非アクティブ状態では出力なし ---"
make_state
jq '.run_state = "OFF"' "$SPRINT_DIR/state.json" > "$SPRINT_DIR/state.json.tmp" \
  && mv "$SPRINT_DIR/state.json.tmp" "$SPRINT_DIR/state.json"
OUTPUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null || true)
if [ -z "$OUTPUT" ]; then
  echo "PASS: OFF状態では出力なし"
  PASS=$((PASS + 1))
else
  echo "FAIL: OFF状態で出力があった"
  FAIL=$((FAIL + 1))
fi

# テストケース2: バイト数キャップが機能する
echo "--- テスト: MAX_INJECT_BYTES=200 でキャップされる ---"
make_state
OUTPUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="200" \
  bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
OUTPUT_BYTES=${#OUTPUT}
if [ "$OUTPUT_BYTES" -le 200 ]; then
  echo "PASS: 出力が 200 bytes 以下 (actual: $OUTPUT_BYTES bytes)"
  PASS=$((PASS + 1))
else
  echo "FAIL: 出力が 200 bytes を超えた (actual: $OUTPUT_BYTES bytes)"
  FAIL=$((FAIL + 1))
fi

# テストケース3: resume_hint.read_first のパスが出力に含まれる
echo "--- テスト: read_first のパスが出力に含まれる ---"
make_state
OUTPUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="5000" \
  bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
if echo "$OUTPUT" | grep -q "sprint/checkpoint.md"; then
  echo "PASS: sprint/checkpoint.md が出力に含まれる"
  PASS=$((PASS + 1))
else
  echo "FAIL: sprint/checkpoint.md が出力に含まれない"
  FAIL=$((FAIL + 1))
fi
if echo "$OUTPUT" | grep -q "sprint/SPRINT.md"; then
  echo "PASS: sprint/SPRINT.md が出力に含まれる"
  PASS=$((PASS + 1))
else
  echo "FAIL: sprint/SPRINT.md が出力に含まれない"
  FAIL=$((FAIL + 1))
fi

# テストケース4: 状態サマリーが含まれる
echo "--- テスト: 状態サマリーが出力される ---"
make_state
OUTPUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="5000" \
  bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
if echo "$OUTPUT" | grep -q "sprint-test"; then
  echo "PASS: sprint_id が出力に含まれる"
  PASS=$((PASS + 1))
else
  echo "FAIL: sprint_id が出力に含まれない"
  FAIL=$((FAIL + 1))
fi
if echo "$OUTPUT" | grep -q "EXECUTE"; then
  echo "PASS: phase が出力に含まれる"
  PASS=$((PASS + 1))
else
  echo "FAIL: phase が出力に含まれない"
  FAIL=$((FAIL + 1))
fi

# テストケース5: 大量データでもキャップが効く（肥大化対策）
echo "--- テスト: 大量データでも MAX_INJECT_BYTES=2000 以内 ---"
# 大きな next_action を持つ state.json
LONG_ACTION=$(python3 -c "print('A' * 5000)" 2>/dev/null || printf '%5000s' | tr ' ' 'A')
make_state "$LONG_ACTION"
OUTPUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="2000" \
  bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
OUTPUT_BYTES=${#OUTPUT}
if [ "$OUTPUT_BYTES" -le 2000 ]; then
  echo "PASS: 大量データでも 2000 bytes 以下 (actual: $OUTPUT_BYTES bytes)"
  PASS=$((PASS + 1))
else
  echo "FAIL: 2000 bytes を超えた (actual: $OUTPUT_BYTES bytes)"
  FAIL=$((FAIL + 1))
fi

# （撤去）使用量リセット後の再開通知は中断・再開機構の撤去に伴い削除した。

# テストケース7: SPRINT.md の全文がダンプされていない（プル型注入）
echo "--- テスト: SPRINT.md 本文が全文ダンプされない ---"
make_state
# ダミーの SPRINT.md を作成（識別子入り）
echo "SPRINT_CONTENT_SENTINEL_XYZ: この文字列は全文ダンプ時のみ現れる" > "$SPRINT_DIR/SPRINT.md"
OUTPUT=$(CLAUDE_PROJECT_DIR="$TMPDIR_TEST" SPRINT_MAX_INJECT_BYTES="5000" \
  bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
if echo "$OUTPUT" | grep -q "SPRINT_CONTENT_SENTINEL_XYZ"; then
  echo "FAIL: SPRINT.md の本文が全文ダンプされている（プル型注入違反）"
  FAIL=$((FAIL + 1))
else
  echo "PASS: SPRINT.md の本文がダンプされていない（パスのみ案内）"
  PASS=$((PASS + 1))
fi

# 結果サマリー
echo ""
echo "================================"
echo "結果: PASS=$PASS, FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
