#!/usr/bin/env bash
# tests/test_subagent_hallucination.sh — サブエージェント幻覚検知の動作確認
#
# 目的:
#   forbidden_patterns の語彙（"おそらく"・"完了したつもり" 等）を含む
#   サブエージェント出力に対して verify-output-contract.sh が必ず FAIL を返すことを確認する。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VERIFY="$REPO_ROOT/scripts/verify-output-contract.sh"
[ -x "$VERIFY" ] || { echo "FAIL: verify not executable: $VERIFY"; exit 1; }

fail=0
pass=0
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint"
echo '{}' > "$tmpdir/sprint/state.json"

# 偽の幻覚出力（"おそらく動く"・"完了したつもり" を含む）
cat > "$tmpdir/halluc.txt" <<'EOF'
作業の結果、おそらく動くと思います。
完了したつもりです。
EOF

cat > "$tmpdir/test.yaml" <<'EOF'
agent: test
required_artifacts: []
forbidden_patterns:
  - "おそらく"
  - "完了したつもり"
EOF

set +e
out=$(cd "$tmpdir" && SPRINT_AGENT_OUTPUT="$tmpdir/halluc.txt" bash "$VERIFY" "$tmpdir/test.yaml" 2>&1)
rc=$?
set -e

if [ "$rc" != "0" ]; then
  pass=$((pass+1)); echo "  PASS: hallucination detected (rc=$rc)"
else
  fail=$((fail+1)); echo "  FAIL: hallucination not detected, output: $out"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
