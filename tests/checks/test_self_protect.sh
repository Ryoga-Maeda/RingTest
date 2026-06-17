#!/usr/bin/env bash
# tests/checks/test_self_protect.sh — R0 self_protect.sh の単体テスト
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT_REPO/.claude/sprint/policy/checks/self_protect.sh"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export ROOT="$T" STATE_FILE="$T/sprint/state.json"

run() { FILE="$1" TOOL="${2:-Write}" bash "$CHECK" "${3:-}" >/dev/null 2>&1; echo $?; }
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected exit=$e got $a)"; FAIL=$((FAIL+1)); fi; }

echo "=== test_self_protect.sh (R0) ==="

# 違反: policy への書込 → deny
expect "[違反] policy/rules.json 書込 → deny" 1 "$(run "$T/.claude/sprint/policy/rules.json")"

# 違反: hooks への書込 → deny
expect "[違反] hooks/_guard.sh 書込 → deny" 1 "$(run "$T/.claude/sprint/hooks/_guard.sh")"

# 違反: 相対パス表記でも deny
expect "[違反] 相対パス .claude/sprint/hooks/x.sh → deny" 1 "$(run ".claude/sprint/hooks/x.sh")"

# 正常: 通常ファイル → allow
expect "[正常] src/foo.ts → allow" 0 "$(run "$T/src/foo.ts")"

# 違反: Bash コマンドでフックへリダイレクト → deny
JSON='{"tool_input":{"command":"echo x > .claude/sprint/hooks/pwn.sh"}}'
expect "[違反] Bash でフックへ書込 → deny" 1 "$(run "" Bash "$JSON")"

# 正常: 無関係な Bash コマンド → allow
JSON2='{"tool_input":{"command":"ls -la"}}'
expect "[正常] 無関係な Bash → allow" 0 "$(run "" Bash "$JSON2")"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
