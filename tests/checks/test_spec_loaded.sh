#!/usr/bin/env bash
# tests/checks/test_spec_loaded.sh — R1 spec_loaded.sh の単体テスト
# 違反=exit1 / 正常=exit0 / 判定不能=exit1 の3パターン
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT_REPO/.claude/sprint/policy/checks/spec_loaded.sh"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sprint" "$T/src"
export ROOT="$T" STATE_FILE="$T/sprint/state.json"

run() { FILE="$1" TOOL="${2:-Write}" bash "$CHECK" >/dev/null 2>&1; echo $?; }
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected exit=$e got $a)"; FAIL=$((FAIL+1)); fi; }

echo "=== test_spec_loaded.sh (R1) ==="

# 正常: contract.agreed=true ＋ SPRINT.md 存在 → src 編集 allow
echo '{"contract":{"agreed":true}}' > "$STATE_FILE"; : > "$T/sprint/SPRINT.md"
expect "[正常] agreed=true で src/foo.ts → allow" 0 "$(run "$T/src/foo.ts")"

# 違反: contract.agreed=false → src 編集 deny
echo '{"contract":{"agreed":false}}' > "$STATE_FILE"
expect "[違反] agreed=false で src/foo.ts → deny" 1 "$(run "$T/src/foo.ts")"

# 違反: SPRINT.md 不在 → deny
echo '{"contract":{"agreed":true}}' > "$STATE_FILE"; rm -f "$T/sprint/SPRINT.md"
expect "[違反] SPRINT.md 不在 → deny" 1 "$(run "$T/src/foo.ts")"

# 対象外: src 外のファイル → allow（contract に関係なく）
echo '{"contract":{"agreed":false}}' > "$STATE_FILE"
expect "[対象外] docs/readme.md → allow" 0 "$(run "$T/docs/readme.md")"

# 対象外: FILE 空（Bash 等） → allow
expect "[対象外] FILE 空 → allow" 0 "$(run "")"

# 判定不能: state.json 破損 → deny（agreed が読めず false 扱い）
echo '{broken' > "$STATE_FILE"
expect "[判定不能] 壊れた state.json で src 編集 → deny" 1 "$(run "$T/src/foo.ts")"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
