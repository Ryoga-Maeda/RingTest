#!/usr/bin/env bash
# T-D.17: test_agent_prefix_concat.sh
# build-agent-prompts.sh が L1 + L2 + L3 を正しく結合することを検証する。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_SCRIPT="$REPO_ROOT/scripts/build-agent-prompts.sh"

[ -x "$BUILD_SCRIPT" ] || { echo "FAIL: build-agent-prompts.sh not executable"; exit 1; }

fail=0
pass=0

# まず build を実行
(cd "$REPO_ROOT" && bash "$BUILD_SCRIPT" >/dev/null)

# 各レイヤーの結合済みファイルを検査
check_concat() {
  local f="$1" expected_l2_hint="$2"
  if [ ! -f "$f" ]; then
    fail=$((fail+1)); echo "  FAIL: $f not built"
    return
  fi
  # L1 ヘッダ確認
  if ! grep -q "V2 フレームワークヘッダ" "$f"; then
    fail=$((fail+1)); echo "  FAIL: $f missing L1 header"
    return
  fi
  # L2 ヒント確認
  if ! grep -qF "$expected_l2_hint" "$f"; then
    fail=$((fail+1)); echo "  FAIL: $f missing L2 hint '$expected_l2_hint'"
    return
  fi
  # frontmatter は L3 のものを保持（name: が含まれる）
  if ! head -10 "$f" | grep -q "^name:"; then
    fail=$((fail+1)); echo "  FAIL: $f missing frontmatter name"
    return
  fi
  pass=$((pass+1)); echo "  PASS: $f concatenated correctly"
}

BUILD_DIR="$REPO_ROOT/.claude/agents/_build"

echo "[phase layer]"
for f in "$BUILD_DIR/phase/"*.md; do
  [ -f "$f" ] || continue
  check_concat "$f" "プロセスリード層 共通プリ"
done

echo "[execution layer]"
for f in "$BUILD_DIR/execution/"*.md; do
  [ -f "$f" ] || continue
  check_concat "$f" "実行層 共通プリ"
done

echo "[infra layer]"
for f in "$BUILD_DIR/infra/"*.md; do
  [ -f "$f" ] || continue
  check_concat "$f" "インフラ層 共通プリ"
done

echo "[orchestrator-v2 (L1+L2 なし)]"
if [ -f "$BUILD_DIR/orchestrator-v2.md" ]; then
  if grep -q "V2 Orchestrator 行動規範" "$BUILD_DIR/orchestrator-v2.md"; then
    pass=$((pass+1)); echo "  PASS: orchestrator-v2 copied as-is"
  else
    fail=$((fail+1)); echo "  FAIL: orchestrator-v2 not properly copied"
  fi
  # 薄殻シェルは L1/L2 を含まないことも検査
  if grep -q "V2 フレームワークヘッダ" "$BUILD_DIR/orchestrator-v2.md"; then
    fail=$((fail+1)); echo "  FAIL: orchestrator-v2 should NOT contain L1 header"
  fi
fi

# 冪等性: 2 回目の build で出力に差分が出ないか検査
echo "[idempotency]"
snapshot=$(mktemp -d)
cp -r "$BUILD_DIR"/* "$snapshot/"
(cd "$REPO_ROOT" && bash "$BUILD_SCRIPT" >/dev/null)
if diff -r "$snapshot" "$BUILD_DIR" >/dev/null 2>&1; then
  pass=$((pass+1)); echo "  PASS: build is idempotent"
else
  fail=$((fail+1)); echo "  FAIL: build is not idempotent"
fi
rm -rf "$snapshot"

echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
