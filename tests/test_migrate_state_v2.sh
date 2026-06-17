#!/usr/bin/env bash
# T-A.14: migrate-state-v2.sh の schema 拡張完備と冪等性を検証
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MIGRATE="$REPO_ROOT/scripts/migrate-state-v2.sh"

[ -x "$MIGRATE" ] || { echo "FAIL: migrate not executable: $MIGRATE"; exit 1; }

fail=0
pass=0

# v1 形式 state.json を一時ディレクトリに用意（v1 を変更しない原則）
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/sprint"
echo '{"phase":"CLARIFY","contract":{"agreed":false},"schema_version":1}' > "$tmpdir/sprint/state.json"

# Case 1: v1 → v2 補完（cwd を tmpdir にして実行）
(cd "$tmpdir" && bash "$MIGRATE") || { echo "FAIL: migrate exit non-zero"; fail=$((fail+1)); }

# 必須拡張フィールドを検証
# persona は null 許可（オプショナル）、それ以外は null 不可
required_keys="v2_active sub_phase improve_iteration phase_advance_last_fired_at triage_artifacts subagent_health subagent_heartbeats gate_approvals schema_version"
for key in $required_keys; do
  val=$(jq -r --arg k "$key" '.[$k]' "$tmpdir/sprint/state.json")
  if [ "$val" = "null" ]; then
    fail=$((fail+1)); echo "  FAIL: $key is null"
  else
    pass=$((pass+1)); echo "  PASS: $key=$val"
  fi
done

# persona は存在自体は確認（null 値は許容）
if jq -e 'has("persona")' "$tmpdir/sprint/state.json" >/dev/null; then
  pass=$((pass+1)); echo "  PASS: persona key exists (null allowed)"
else
  fail=$((fail+1)); echo "  FAIL: persona key missing"
fi

# schema_version=2 にバンプ
sv=$(jq -r '.schema_version' "$tmpdir/sprint/state.json")
if [ "$sv" = "2" ]; then
  pass=$((pass+1)); echo "  PASS: schema_version=2"
else
  fail=$((fail+1)); echo "  FAIL: schema_version=$sv (expected 2)"
fi

# 既存フィールド保持
ph=$(jq -r '.phase' "$tmpdir/sprint/state.json")
if [ "$ph" = "CLARIFY" ]; then
  pass=$((pass+1)); echo "  PASS: phase preserved (CLARIFY)"
else
  fail=$((fail+1)); echo "  FAIL: phase=$ph (expected CLARIFY)"
fi

ca=$(jq -r '.contract.agreed' "$tmpdir/sprint/state.json")
if [ "$ca" = "false" ]; then
  pass=$((pass+1)); echo "  PASS: contract.agreed preserved (false)"
else
  fail=$((fail+1)); echo "  FAIL: contract.agreed=$ca (expected false)"
fi

# Case 2: 冪等性（2 回実行しても hash 不変）
hash1=$(sha256sum "$tmpdir/sprint/state.json" | cut -d' ' -f1)
(cd "$tmpdir" && bash "$MIGRATE") || { echo "FAIL: 2nd migrate exit non-zero"; fail=$((fail+1)); }
hash2=$(sha256sum "$tmpdir/sprint/state.json" | cut -d' ' -f1)
if [ "$hash1" = "$hash2" ]; then
  pass=$((pass+1)); echo "  PASS: idempotent (hash unchanged)"
else
  fail=$((fail+1)); echo "  FAIL: hash changed on 2nd run (h1=$hash1 h2=$hash2)"
fi

echo "Total: pass=$pass fail=$fail"
if [ "$fail" = "0" ]; then
  echo "PASS: test_migrate_state_v2"
  exit 0
else
  echo "FAIL: test_migrate_state_v2 ($fail failures)"
  exit 1
fi
