#!/usr/bin/env bash
# tests/test_guard.sh — _guard.sh の単体テスト（P0-3）
set -euo pipefail

PASS=0
FAIL=0
GUARD="$(git rev-parse --show-toplevel)/.claude/sprint/hooks/_guard.sh"

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_guard.sh ==="

# Case 1: state.json 不在 → no-op（"REACHED" が出力されない）
rm -rf /tmp/sprint_test && mkdir -p /tmp/sprint_test/sprint
actual=$(CLAUDE_PROJECT_DIR=/tmp/sprint_test bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
check "state.json 不在 → no-op" "" "$actual"

# Case 2: run_state=OFF → no-op
mkdir -p /tmp/sprint_test/sprint
echo '{"run_state":"OFF"}' > /tmp/sprint_test/sprint/state.json
actual=$(CLAUDE_PROJECT_DIR=/tmp/sprint_test bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
check "run_state=OFF → no-op" "" "$actual"

# Case 3: run_state=RUNNING → 継続
echo '{"run_state":"RUNNING"}' > /tmp/sprint_test/sprint/state.json
actual=$(CLAUDE_PROJECT_DIR=/tmp/sprint_test bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
check "run_state=RUNNING → 継続" "REACHED" "$actual"

# Case 4: run_state=COMPLETE（終端正常）→ no-op（フックは効かない）
echo '{"run_state":"COMPLETE"}' > /tmp/sprint_test/sprint/state.json
actual=$(CLAUDE_PROJECT_DIR=/tmp/sprint_test bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
check "run_state=COMPLETE → no-op（終端）" "" "$actual"

# Case 5: run_state=ABORTED（終端致命）→ no-op（フックは効かない）
echo '{"run_state":"ABORTED"}' > /tmp/sprint_test/sprint/state.json
actual=$(CLAUDE_PROJECT_DIR=/tmp/sprint_test bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
check "run_state=ABORTED → no-op（終端）" "" "$actual"

# Case 5b: 廃止集合（CHECKPOINTING/SUSPENDED）も no-op（撤去済み）
for s in CHECKPOINTING SUSPENDED; do
  echo "{\"run_state\":\"$s\"}" > /tmp/sprint_test/sprint/state.json
  actual=$(CLAUDE_PROJECT_DIR=/tmp/sprint_test bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
  check "run_state=$s（廃止集合）→ no-op" "" "$actual"
done

# Case 6: 壊れた JSON → no-op（Fail-safe）
echo '{broken json' > /tmp/sprint_test/sprint/state.json
actual=$(CLAUDE_PROJECT_DIR=/tmp/sprint_test bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
check "壊れたJSON → no-op（Fail-safe）" "" "$actual"

# クリーンアップ
rm -rf /tmp/sprint_test

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
