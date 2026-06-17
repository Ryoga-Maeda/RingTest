#!/usr/bin/env bash
# tests/test_phase_advance_debounce.sh — phase-advance.sh のデバウンス機構検証
#
# 検査内容:
#   100ms 間隔で phase-advance.sh を 10 回呼び、内部の apply / eval の実行回数が
#   1 回であることを検証する。既定閾値 1000ms（テストでは余裕を持って 1200ms）で
#   100ms × 10 = 1000ms 内に収まるため、debounce により 1 回に集約される。
#
#   さらに、閾値超過後（sleep 2s）の呼出で apply/eval が再発火することを確認する。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HOOK="$REPO_ROOT/.claude/sprint/hooks/phase-advance.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK"; exit 1; }

fail=0
pass=0

# 一時ディレクトリ準備
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/sprint" "$tmpdir/scripts" "$tmpdir/.claude/sprint/hooks"

# v2_active=true な state.json
cat > "$tmpdir/sprint/state.json" <<'EOF'
{
  "phase": "CLARIFY",
  "sub_phase": "implement",
  "v2_active": true,
  "schema_version": 2,
  "gate_approvals": {},
  "phase_advance_last_fired_at": 0
}
EOF

# apply / eval をスタブに差し替え（カウンタファイルに追記）
cat > "$tmpdir/scripts/phase-advance-apply.sh" <<'EOF'
#!/usr/bin/env bash
echo apply >> "$STUB_COUNT_FILE"
EOF
cat > "$tmpdir/scripts/phase-advance-eval.sh" <<'EOF'
#!/usr/bin/env bash
echo eval >> "$STUB_COUNT_FILE"
echo "test instruction"
EOF
chmod +x "$tmpdir/scripts/phase-advance-apply.sh" "$tmpdir/scripts/phase-advance-eval.sh"

# フック本体をコピー（tmpdir 配下で動かす）
cp "$HOOK" "$tmpdir/.claude/sprint/hooks/phase-advance.sh"
chmod +x "$tmpdir/.claude/sprint/hooks/phase-advance.sh"

# カウンタファイル
export STUB_COUNT_FILE="$tmpdir/counter.log"
: > "$STUB_COUNT_FILE"

# 既定 1000ms だと 100ms × 10 = 1000ms ぴったりで境界が不安定。
# 1200ms にして「10 回呼出が確実に閾値内に収まる」状況を作る。
export SPRINT_PHASE_ADVANCE_DEBOUNCE_MS=1200

# 100ms 間隔で 10 回呼出
for i in $(seq 1 10); do
  (cd "$tmpdir" && bash .claude/sprint/hooks/phase-advance.sh < /dev/null >/dev/null 2>&1) || true
  sleep 0.1
done

apply_count=$(grep -c '^apply$' "$STUB_COUNT_FILE" 2>/dev/null || echo 0)
eval_count=$(grep -c '^eval$' "$STUB_COUNT_FILE" 2>/dev/null || echo 0)

# 期待値: 1 回ずつ
if [ "$apply_count" = "1" ]; then
  pass=$((pass+1)); echo "  PASS: apply called once within debounce window (got $apply_count)"
else
  fail=$((fail+1)); echo "  FAIL: apply called $apply_count times within debounce window (expected 1)"
fi
if [ "$eval_count" = "1" ]; then
  pass=$((pass+1)); echo "  PASS: eval called once within debounce window (got $eval_count)"
else
  fail=$((fail+1)); echo "  FAIL: eval called $eval_count times within debounce window (expected 1)"
fi

# debounce 解除を確認: 閾値 1200ms を超える間隔（2 秒）を空けて再呼出
sleep 2
(cd "$tmpdir" && bash .claude/sprint/hooks/phase-advance.sh < /dev/null >/dev/null 2>&1) || true

apply_count2=$(grep -c '^apply$' "$STUB_COUNT_FILE" 2>/dev/null || echo 0)
eval_count2=$(grep -c '^eval$' "$STUB_COUNT_FILE" 2>/dev/null || echo 0)

if [ "$apply_count2" = "2" ]; then
  pass=$((pass+1)); echo "  PASS: apply re-fired after debounce window expired (got $apply_count2)"
else
  fail=$((fail+1)); echo "  FAIL: apply count after debounce expiry = $apply_count2 (expected 2)"
fi
if [ "$eval_count2" = "2" ]; then
  pass=$((pass+1)); echo "  PASS: eval re-fired after debounce window expired (got $eval_count2)"
else
  fail=$((fail+1)); echo "  FAIL: eval count after debounce expiry = $eval_count2 (expected 2)"
fi

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
