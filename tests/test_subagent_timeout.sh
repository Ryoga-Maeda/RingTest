#!/usr/bin/env bash
# heartbeat T1 検知テスト
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CHECK="$REPO_ROOT/scripts/check-heartbeats.sh"

[ -x "$CHECK" ] || { echo "FAIL: check-heartbeats.sh not executable"; exit 1; }

fail=0
pass=0

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/sprint"

# 60 分前 (3600000 ms 前) の started_at
old_started=$(( ($(date +%s%N) / 1000000) - 3600000 ))
recent_started=$(( ($(date +%s%N) / 1000000) - 60000 ))   # 60 秒前

cat > "$tmpdir/sprint/state.json" <<EOF
{
  "phase": "EXECUTE",
  "subagent_heartbeats": {
    "investigator": { "started_at": ${old_started} },
    "worker": { "started_at": ${recent_started} }
  },
  "subagent_health": {}
}
EOF

(cd "$tmpdir" && bash "$CHECK") > "$tmpdir/out.log"

# investigator が T1 detected として出力されている
if grep -q "T1 detected: investigator" "$tmpdir/out.log"; then
  pass=$((pass+1)); echo "  PASS: investigator T1 detected"
else
  fail=$((fail+1)); echo "  FAIL: investigator T1 not detected"
fi

# worker は出ない（まだ 60 秒）
if ! grep -q "T1 detected: worker" "$tmpdir/out.log"; then
  pass=$((pass+1)); echo "  PASS: worker T1 not falsely detected"
else
  fail=$((fail+1)); echo "  FAIL: worker T1 falsely detected"
fi

# state.json に書き込まれた
recorded=$(jq -r '.subagent_health.investigator.t1_timeout_at // 0' "$tmpdir/sprint/state.json")
if [ "$recorded" -gt "0" ]; then
  pass=$((pass+1)); echo "  PASS: subagent_health.investigator.t1_timeout_at recorded"
else
  fail=$((fail+1)); echo "  FAIL: t1_timeout_at not recorded"
fi

rm -rf "$tmpdir"
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
