#!/usr/bin/env bash
# R3' 強制テスト: 改善フェーズで「最初の commit がテストファイルのみ」を強制することを確認する。
# Case 1: improve フェーズで非テストファイル混入 → block
# Case 2: improve フェーズでテストファイルのみ → pass
# Case 3: implement フェーズなら R3' 不適用 → pass
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CHECK="$REPO_ROOT/.claude/sprint/policy/checks/r3prime_check.sh"

[ -x "$CHECK" ] || { echo "FAIL: r3prime_check.sh not executable"; exit 1; }

fail=0
pass=0

# ---- Case 1: improve / 非テストファイル → block ----
tmpdir=$(mktemp -d)
(
  cd "$tmpdir"
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git checkout -q -b "improve/test-sprint/I-001"

  mkdir -p sprint/tasks
  cat > sprint/state.json <<'EOF'
{ "v2_active": true, "sub_phase": "improve" }
EOF
  echo '{}' > sprint/tasks/I-001.status.json
  git add sprint/

  mkdir -p src
  echo "function foo() {}" > src/foo.js  # 非テストファイル
  git add src/foo.js

  mkdir -p .claude/sprint/policy/checks
  cp "$CHECK" .claude/sprint/policy/checks/r3prime_check.sh
  chmod +x .claude/sprint/policy/checks/r3prime_check.sh

  set +e
  bash .claude/sprint/policy/checks/r3prime_check.sh 2>/dev/null
  echo "RC=$?" > /tmp/r3p_case1_rc
  set -e
)
rc=$(grep -oE '[0-9]+' /tmp/r3p_case1_rc | head -1)
if [ "$rc" != "0" ]; then
  pass=$((pass+1)); echo "  PASS: Case1 non-test file in first improve commit blocked"
else
  fail=$((fail+1)); echo "  FAIL: Case1 non-test file should have been blocked"
fi
rm -rf "$tmpdir" /tmp/r3p_case1_rc

# ---- Case 2: improve / テストファイルのみ → pass ----
tmpdir=$(mktemp -d)
(
  cd "$tmpdir"
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git checkout -q -b "improve/test-sprint/I-002"

  mkdir -p sprint/tasks
  cat > sprint/state.json <<'EOF'
{ "v2_active": true, "sub_phase": "improve" }
EOF
  echo '{}' > sprint/tasks/I-002.status.json

  mkdir -p tests
  echo "echo test" > tests/test_foo.sh
  git add tests/test_foo.sh sprint/

  mkdir -p .claude/sprint/policy/checks
  cp "$CHECK" .claude/sprint/policy/checks/r3prime_check.sh
  chmod +x .claude/sprint/policy/checks/r3prime_check.sh

  set +e
  bash .claude/sprint/policy/checks/r3prime_check.sh 2>/dev/null
  echo "RC=$?" > /tmp/r3p_case2_rc
  set -e
)
rc=$(grep -oE '[0-9]+' /tmp/r3p_case2_rc | head -1)
if [ "$rc" = "0" ]; then
  pass=$((pass+1)); echo "  PASS: Case2 test-only first commit passes"
else
  fail=$((fail+1)); echo "  FAIL: Case2 test-only commit was blocked (rc=$rc)"
fi
rm -rf "$tmpdir" /tmp/r3p_case2_rc

# ---- Case 3: implement フェーズ → R3' 不適用 ----
tmpdir=$(mktemp -d)
(
  cd "$tmpdir"
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git checkout -q -b "task/test-sprint/T-001"

  mkdir -p sprint
  cat > sprint/state.json <<'EOF'
{ "v2_active": true, "sub_phase": "implement" }
EOF

  mkdir -p src
  echo "function foo() {}" > src/foo.js
  git add src/

  mkdir -p .claude/sprint/policy/checks
  cp "$CHECK" .claude/sprint/policy/checks/r3prime_check.sh
  chmod +x .claude/sprint/policy/checks/r3prime_check.sh

  set +e
  bash .claude/sprint/policy/checks/r3prime_check.sh 2>/dev/null
  echo "RC=$?" > /tmp/r3p_case3_rc
  set -e
)
rc=$(grep -oE '[0-9]+' /tmp/r3p_case3_rc | head -1)
if [ "$rc" = "0" ]; then
  pass=$((pass+1)); echo "  PASS: Case3 implement phase skipped R3' check"
else
  fail=$((fail+1)); echo "  FAIL: Case3 implement phase was incorrectly blocked"
fi
rm -rf "$tmpdir" /tmp/r3p_case3_rc

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
