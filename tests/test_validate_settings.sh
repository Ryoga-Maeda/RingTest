#!/usr/bin/env bash
# tests/test_validate_settings.sh
# FR-2: scripts/validate-settings.sh の単体テスト（JSON 妥当性＋フック登録スキーマ適合）
#
# 検証:
#   - 正常な settings（hooks 付き / hooks 無し）→ exit 0
#   - 不正 JSON → exit 非0（拒否）
#   - hooks スキーマ崩れ（command 欠落 / イベントが配列でない）→ exit 非0（拒否）

set -uo pipefail
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATE="$SCRIPT_DIR/scripts/validate-settings.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# 正常な settings（hooks 付き）→ exit 0
cat > "$T/good.json" <<'EOF'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "bash x.sh" } ] } ] } }
EOF
rc=0; bash "$VALIDATE" "$T/good.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && pass "正常な settings（hooks 付き）は exit 0" || fail "正常 settings exit 0 (rc=$rc)"

# 無害設定のみ（hooks 無し）→ exit 0
cat > "$T/clean.json" <<'EOF'
{ "language": "ja", "env": { "X": "1" } }
EOF
rc=0; bash "$VALIDATE" "$T/clean.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && pass "hooks 無し設定は exit 0" || fail "hooks 無し exit 0 (rc=$rc)"

# 不正 JSON → exit 非0
printf '{ "hooks": { broken json\n' > "$T/broken.json"
rc=0; bash "$VALIDATE" "$T/broken.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && pass "不正 JSON は拒否（exit 非0）" || fail "不正 JSON 拒否 (rc=$rc)"

# hooks スキーマ崩れ（command 欠落）→ exit 非0
cat > "$T/badschema.json" <<'EOF'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command" } ] } ] } }
EOF
rc=0; bash "$VALIDATE" "$T/badschema.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && pass "command 欠落のフック登録は拒否" || fail "command 欠落拒否 (rc=$rc)"

# hooks イベントが配列でない → exit 非0
cat > "$T/badevent.json" <<'EOF'
{ "hooks": { "Stop": { "type": "command", "command": "x" } } }
EOF
rc=0; bash "$VALIDATE" "$T/badevent.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && pass "イベントが配列でない登録は拒否" || fail "非配列イベント拒否 (rc=$rc)"

# 複数ファイル一括検証で1つでも壊れていれば非0
rc=0; bash "$VALIDATE" "$T/good.json" "$T/broken.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && pass "複数指定で1つでも壊れていれば拒否" || fail "複数指定の拒否 (rc=$rc)"

echo ""
echo "================================"
echo "結果: PASS=$PASS, FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
