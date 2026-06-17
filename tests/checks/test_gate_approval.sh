#!/usr/bin/env bash
# tests/checks/test_gate_approval.sh — R5 gate_approval.sh の単体テスト
# (a) gate_approvals.json への書込は常時 deny（自己承認防止）
# (b) CLARIFY での state.json 書込は承認の有無で allow/deny
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT_REPO/.claude/sprint/policy/checks/gate_approval.sh"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sprint" "$T/src"
export ROOT="$T" STATE_FILE="$T/sprint/state.json"
APPROVALS="$T/sprint/gate_approvals.json"

run() { FILE="$1" TOOL="${2:-Write}" bash "$CHECK" >/dev/null 2>&1; echo $?; }
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected exit=$e got $a)"; FAIL=$((FAIL+1)); fi; }

echo "=== test_gate_approval.sh (R5) ==="

# (a) 自己承認防止: gate_approvals.json への書込は承認状態に関わらず常時 deny
echo '{"phase":"CLARIFY"}' > "$STATE_FILE"; echo '{}' > "$APPROVALS"
expect "[違反] gate_approvals.json への Write → deny（自己承認防止）" 1 "$(run "$T/sprint/gate_approvals.json")"

# (b) 違反: CLARIFY ＋ 承認なし で state.json 書込 → deny
echo '{"phase":"CLARIFY"}' > "$STATE_FILE"; echo '{"CLARIFY_TO_DESIGN":null}' > "$APPROVALS"
expect "[違反] CLARIFY 承認なしで state.json 書込 → deny" 1 "$(run "$T/sprint/state.json")"

# (b) 正常: CLARIFY ＋ 承認あり → allow
echo '{"phase":"CLARIFY"}' > "$STATE_FILE"
echo '{"CLARIFY_TO_DESIGN":{"approved_by":"human","approved_at":"2026-06-01T00:00:00Z"}}' > "$APPROVALS"
expect "[正常] CLARIFY 承認ありで state.json 書込 → allow" 0 "$(run "$T/sprint/state.json")"

# 対象外: CLARIFY 以外のフェーズ → allow
echo '{"phase":"EXECUTE"}' > "$STATE_FILE"; echo '{}' > "$APPROVALS"
expect "[対象外] EXECUTE フェーズ → allow" 0 "$(run "$T/sprint/state.json")"

# 対象外: state.json/gate_approvals.json 以外のファイル → allow
echo '{"phase":"CLARIFY"}' > "$STATE_FILE"
expect "[対象外] src/foo.ts → allow" 0 "$(run "$T/src/foo.ts")"

# 境界: 承認ファイル破損 → 承認読めず deny（fail-closed 寄り）
echo '{"phase":"CLARIFY"}' > "$STATE_FILE"; echo '{broken' > "$APPROVALS"
expect "[fail-closed] 承認ファイル破損で CLARIFY state.json 書込 → deny" 1 "$(run "$T/sprint/state.json")"

# (c) ハッシュ照合（H-1）: 承認時の PRODUCT.md ハッシュと現在が一致 → allow
echo '{"phase":"CLARIFY"}' > "$STATE_FILE"
echo "ゴール v1" > "$T/sprint/PRODUCT.md"
PHASH="sha256:$(sha256sum "$T/sprint/PRODUCT.md" | awk '{print $1}')"
jq -n --arg h "$PHASH" '{CLARIFY_TO_DESIGN:{approved_by:"human",approved_at:"2026-06-01T00:00:00Z",product_md_hash:$h}}' > "$APPROVALS"
expect "[正常] 承認あり＋PRODUCT.md ハッシュ一致 → allow" 0 "$(run "$T/sprint/state.json")"

# (c) ハッシュ照合（H-1）: 承認後に PRODUCT.md を改変 → ハッシュ不一致 → deny（再承認要求）
echo "ゴール v2（承認後に書き換え）" > "$T/sprint/PRODUCT.md"
expect "[違反] 承認後に PRODUCT.md 改変（ハッシュ不一致）→ deny" 1 "$(run "$T/sprint/state.json")"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
