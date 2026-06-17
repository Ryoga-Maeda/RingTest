#!/usr/bin/env bash
# T-A.12: orchestrator-v2.md が薄殻（Task/AskUserQuestion のみ）であることを静的検査
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_ROOT/.claude/agents/orchestrator-v2.md"

[ -f "$TARGET" ] || { echo "FAIL: $TARGET not found"; exit 1; }

fail=0
pass=0

# 1) frontmatter の tools 配列検査
# 最初の --- と 2 番目の --- の間を frontmatter として抽出
fm=$(awk 'BEGIN{f=0} /^---$/{f++; next} f==1{print}' "$TARGET")
tools_line=$(echo "$fm" | grep -E '^tools:' || true)
if [ -z "$tools_line" ]; then
  echo "FAIL: tools frontmatter not found"; fail=$((fail+1))
else
  # 禁止: Bash, Edit, Write, Read
  for forbidden in Bash Edit Write Read; do
    if echo "$tools_line" | grep -qw "$forbidden"; then
      echo "FAIL: forbidden tool '$forbidden' present in tools: $tools_line"; fail=$((fail+1))
    else
      pass=$((pass+1)); echo "  PASS: forbidden tool '$forbidden' absent"
    fi
  done
  # 必須: Task, AskUserQuestion
  for required in Task AskUserQuestion; do
    if ! echo "$tools_line" | grep -qw "$required"; then
      echo "FAIL: required tool '$required' missing in tools: $tools_line"; fail=$((fail+1))
    else
      pass=$((pass+1)); echo "  PASS: required tool '$required' present"
    fi
  done
fi

# 2) 本文（2 番目の --- 以降）の文言検査
body=$(awk 'BEGIN{f=0} /^---$/{f++; next} f==2{print}' "$TARGET")
for phrase in "state.json を直接読まない" "git を直接操作しない" "フックの指示" "3 行サマリ"; do
  if ! echo "$body" | grep -qF "$phrase"; then
    echo "FAIL: missing phrase '$phrase' in body"; fail=$((fail+1))
  else
    pass=$((pass+1)); echo "  PASS: phrase '$phrase' present"
  fi
done

# 3) 「Bash は無い」の文言（明文化の確認）
if ! echo "$body" | grep -qF "Bash は無い"; then
  echo "FAIL: missing phrase 'Bash は無い' in body"; fail=$((fail+1))
else
  pass=$((pass+1)); echo "  PASS: phrase 'Bash は無い' present"
fi

echo "Total: pass=$pass fail=$fail"
if [ "$fail" = "0" ]; then
  echo "PASS: test_orchestrator_thin_shell"
  exit 0
else
  echo "FAIL: test_orchestrator_thin_shell ($fail failures)"
  exit 1
fi
