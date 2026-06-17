#!/usr/bin/env bash
# tests/test_optin_noop.sh
# オプトイン無害性の回帰テスト: run_state=OFF のとき 4 フックが no-op であること。
# 設定を .claude/settings.json に統合しても、_guard.sh により OFF 時は無害であることを守る。
set -euo pipefail
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$T/sprint" "$T/.claude/sprint/hooks"
# フック本体一式をコピー
cp "$SCRIPT_DIR/.claude/sprint/hooks/"*.sh "$T/.claude/sprint/hooks/"
# §11.2 R-1: v1 RULES.md → V2 L1 フレームワークヘッダに切替
mkdir -p "$T/.claude/agents/_prefix"
[ -f "$SCRIPT_DIR/.claude/agents/_prefix/L1-framework-header.md" ] && \
  cp "$SCRIPT_DIR/.claude/agents/_prefix/L1-framework-header.md" "$T/.claude/agents/_prefix/" 2>/dev/null || true

check(){ local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "PASS: $d"; PASS=$((PASS+1)); else echo "FAIL: $d (expected='$e' got='$a')"; FAIL=$((FAIL+1)); fi; }

# run_state=OFF の state.json（使用量スキーマは撤去済み・レジリエンスは .resilience）
cat > "$T/sprint/state.json" << 'EOF'
{
  "sprint_id": "s-off",
  "phase": "EXECUTE",
  "run_state": "OFF",
  "contract": {"agreed": false, "iteration": 0, "max_iterations": 15},
  "tasks": {},
  "resilience": {"consecutive_tool_failures": 0, "persist_failed": false, "persist_failed_branches": []},
  "resume_hint": {"current_task": null, "read_first": [], "next_action": null},
  "escalations_active": []
}
EOF
SNAPSHOT=$(cat "$T/sprint/state.json")

# session-start.sh: OFF なら出力なし（no-op）
OUT=$(CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/sprint/hooks/session-start.sh" 2>/dev/null)
check "session-start は OFF で無出力" "" "$OUT"

# pre-task.sh: OFF なら exit 0（ブロックしない）
EC=0; printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"x"}}' \
  | CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/sprint/hooks/pre-task.sh" >/dev/null 2>&1 || EC=$?
check "pre-task は OFF で exit 0" "0" "$EC"

# post-task.sh: OFF なら state を変えない
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"x"}}' \
  | CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/sprint/hooks/post-task.sh" >/dev/null 2>&1 || true
check "post-task は OFF で state 不変" "$SNAPSHOT" "$(cat "$T/sprint/state.json")"

# on-stop.sh: OFF なら state を変えない & checkpoint.md を作らない
CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/sprint/hooks/on-stop.sh" >/dev/null 2>&1 || true
check "on-stop は OFF で state 不変" "$SNAPSHOT" "$(cat "$T/sprint/state.json")"
check "on-stop は OFF で checkpoint.md を作らない" "no" "$([ -f "$T/sprint/checkpoint.md" ] && echo yes || echo no)"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
