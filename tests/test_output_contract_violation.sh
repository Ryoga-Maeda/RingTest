#!/usr/bin/env bash
# tests/test_output_contract_violation.sh — output-contract 違反検知の動作確認
#
# 目的:
#   verify-output-contract.sh / quarantine-agent.sh の挙動を確認する。
#   1. forbidden_patterns に違反するサブエージェント出力が verify で FAIL になる
#   2. quarantine-agent.sh が state.json に quarantine_until を書き込む
#   3. クリーンな出力では verify が PASS になる
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VERIFY="$REPO_ROOT/scripts/verify-output-contract.sh"
QUARANTINE="$REPO_ROOT/scripts/quarantine-agent.sh"

[ -x "$VERIFY" ] || { echo "FAIL: verify not executable: $VERIFY"; exit 1; }
[ -x "$QUARANTINE" ] || { echo "FAIL: quarantine not executable: $QUARANTINE"; exit 1; }

fail=0
pass=0

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint"
echo '{"subagent_health":{}}' > "$tmpdir/sprint/state.json"

# 偽のサブエージェント出力（forbidden_patterns 違反: "おそらく"）
cat > "$tmpdir/agent_output.txt" <<'EOF'
タスク完了しました。
おそらく動作するはずです。
EOF

# 偽のコントラクト
cat > "$tmpdir/test.yaml" <<'EOF'
agent: test-agent
required_artifacts: []
required_state_updates: []
forbidden_patterns:
  - "おそらく"
EOF

# verify 実行 → FAIL を期待
set +e
(cd "$tmpdir" && SPRINT_AGENT_OUTPUT="$tmpdir/agent_output.txt" bash "$VERIFY" "$tmpdir/test.yaml" 2>/dev/null)
rc=$?
set -e
if [ "$rc" != "0" ]; then
  pass=$((pass+1)); echo "  PASS: verify failed as expected (rc=$rc)"
else
  fail=$((fail+1)); echo "  FAIL: verify should have failed but passed"
fi

# quarantine 実行 → state.json に書込確認
(cd "$tmpdir" && bash "$QUARANTINE" "test-agent" >/dev/null)
until_ms=$(jq -r '.subagent_health."test-agent".quarantine_until // 0' "$tmpdir/sprint/state.json")
if [ "$until_ms" -gt "0" ] 2>/dev/null; then
  pass=$((pass+1)); echo "  PASS: quarantine_until set (=$until_ms)"
else
  fail=$((fail+1)); echo "  FAIL: quarantine_until not set (got '$until_ms')"
fi

# クリーン出力で PASS することも確認
cat > "$tmpdir/clean_output.txt" <<'EOF'
タスク完了しました。
全テスト PASS、結果を state.json に書き込みました。
EOF
set +e
(cd "$tmpdir" && SPRINT_AGENT_OUTPUT="$tmpdir/clean_output.txt" bash "$VERIFY" "$tmpdir/test.yaml" 2>/dev/null)
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass=$((pass+1)); echo "  PASS: clean output passes verify"
else
  fail=$((fail+1)); echo "  FAIL: clean output failed verify (rc=$rc)"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
