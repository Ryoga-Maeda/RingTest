#!/usr/bin/env bash
# tests/test_resilience_optin.sh — scripts/resilience.sh（ストール回復オプトイン）の単体テスト
# 不変条件: env のみ注入し hooks/statusLine は触らない（規律ゲートを有効化しない＝隔離維持）。
set -euo pipefail
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/resilience.sh"
LOCAL="$T/.claude/settings.local.json"
check(){ local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "PASS: $d"; PASS=$((PASS+1)); else echo "FAIL: $d (expected='$e' got='$a')"; FAIL=$((FAIL+1)); fi; }
# テスト間で状態が漏れないよう .claude を毎回まっさらにする
reset(){ rm -rf "$T/.claude"; }

# ── on（新規）: settings.local.json が作られ .env に3キーが入る。hooks は不在（隔離維持）。
reset
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on >/dev/null 2>&1
check "on（新規）でファイルが作られる" "yes" "$([ -f "$LOCAL" ] && echo yes || echo no)"
check "on（新規）.env.CLAUDE_ENABLE_STREAM_WATCHDOG=1" "1" "$(jq -r '.env.CLAUDE_ENABLE_STREAM_WATCHDOG // "MISSING"' "$LOCAL")"
check "on（新規）.env.API_TIMEOUT_MS=300000" "300000" "$(jq -r '.env.API_TIMEOUT_MS // "MISSING"' "$LOCAL")"
check "on（新規）.env.CLAUDE_CODE_MAX_RETRIES=10" "10" "$(jq -r '.env.CLAUDE_CODE_MAX_RETRIES // "MISSING"' "$LOCAL")"
check "on（新規）hooks は注入されない（隔離維持）" "no" "$(jq -e '.hooks' "$LOCAL" >/dev/null 2>&1 && echo yes || echo no)"
check "on（新規）statusLine は注入されない" "no" "$(jq -e '.statusLine' "$LOCAL" >/dev/null 2>&1 && echo yes || echo no)"

# ── on（既存マージ）: 事前に hooks.X と env.FOO を置き、保持されたまま3キーが追加される。
reset
mkdir -p "$T/.claude"
echo '{"hooks":{"X":1},"env":{"FOO":"bar"}}' > "$LOCAL"
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on >/dev/null 2>&1
check "on（マージ）既存 hooks.X が保持される" "1" "$(jq -r '.hooks.X // "MISSING"' "$LOCAL")"
check "on（マージ）既存 env.FOO が保持される" "bar" "$(jq -r '.env.FOO // "MISSING"' "$LOCAL")"
check "on（マージ）3キーが追加される" "1" "$(jq -r '.env.CLAUDE_ENABLE_STREAM_WATCHDOG // "MISSING"' "$LOCAL")"

# ── on（オーバーライド）: API_TIMEOUT_MS=120000 で注入値が上書きされる。
reset
API_TIMEOUT_MS=120000 CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on >/dev/null 2>&1
check "on（オーバーライド）API_TIMEOUT_MS=120000" "120000" "$(jq -r '.env.API_TIMEOUT_MS // "MISSING"' "$LOCAL")"

# ── on（冪等）: 2回 on しても壊れず3キーのまま。
reset
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on >/dev/null 2>&1
check "on（冪等）env のキー数が3のまま" "3" "$(jq -r '.env | keys | length' "$LOCAL")"
check "on（冪等）hooks は依然不在" "no" "$(jq -e '.hooks' "$LOCAL" >/dev/null 2>&1 && echo yes || echo no)"

# ── on（fail-safe）: 壊れた JSON を置いて on → 上書きされず exit 非ゼロ。
reset
mkdir -p "$T/.claude"
printf '%s' '{bad' > "$LOCAL"
EC=0; CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on >/dev/null 2>&1 || EC=$?
check "on（fail-safe）壊れた JSON で exit 非ゼロ" "yes" "$([ "$EC" -ne 0 ] && echo yes || echo no)"
check "on（fail-safe）内容は不変（上書きしない）" '{bad' "$(cat "$LOCAL")"

# ── off: 3キー＋ユーザー env を置き、off 後に3キーが消え env.FOO は残る。
reset
mkdir -p "$T/.claude"
echo '{"env":{"FOO":"bar","API_TIMEOUT_MS":"300000","CLAUDE_ENABLE_STREAM_WATCHDOG":"1","CLAUDE_CODE_MAX_RETRIES":"10"}}' > "$LOCAL"
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" off >/dev/null 2>&1
check "off で API_TIMEOUT_MS が消える" "no" "$(jq -e '.env.API_TIMEOUT_MS' "$LOCAL" >/dev/null 2>&1 && echo yes || echo no)"
check "off で CLAUDE_ENABLE_STREAM_WATCHDOG が消える" "no" "$(jq -e '.env.CLAUDE_ENABLE_STREAM_WATCHDOG' "$LOCAL" >/dev/null 2>&1 && echo yes || echo no)"
check "off で CLAUDE_CODE_MAX_RETRIES が消える" "no" "$(jq -e '.env.CLAUDE_CODE_MAX_RETRIES' "$LOCAL" >/dev/null 2>&1 && echo yes || echo no)"
check "off でユーザー env.FOO は残る" "bar" "$(jq -r '.env.FOO // "MISSING"' "$LOCAL")"

# ── off（全空→削除）: .env が3キーのみ → off でファイルごと削除。
reset
mkdir -p "$T/.claude"
echo '{"env":{"API_TIMEOUT_MS":"300000","CLAUDE_ENABLE_STREAM_WATCHDOG":"1","CLAUDE_CODE_MAX_RETRIES":"10"}}' > "$LOCAL"
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" off >/dev/null 2>&1
check "off（全空）でファイルごと削除される" "no" "$([ -f "$LOCAL" ] && echo yes || echo no)"

# ── off（hooks 保持）: hooks のみ → off しても hooks は残り、ファイルは消えない。
reset
mkdir -p "$T/.claude"
echo '{"hooks":{"X":1}}' > "$LOCAL"
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" off >/dev/null 2>&1
check "off（hooks 保持）hooks.X は残る" "1" "$(jq -r '.hooks.X // "MISSING"' "$LOCAL")"
check "off（hooks 保持）ファイルは消えない" "yes" "$([ -f "$LOCAL" ] && echo yes || echo no)"

# ── off（ファイル不在）: 何もせず exit 0。
reset
EC=0; CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" off >/dev/null 2>&1 || EC=$?
check "off（不在）exit 0" "0" "$EC"

# ── off（fail-safe）: 壊れた JSON は触らない。
reset
mkdir -p "$T/.claude"
printf '%s' '{bad' > "$LOCAL"
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" off >/dev/null 2>&1 || true
check "off（fail-safe）壊れた JSON は不変" '{bad' "$(cat "$LOCAL")"

# ── status: on 後は「有効」、off 後は「無効」と表示。
reset
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on >/dev/null 2>&1
ST_ON="$(CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" status 2>&1)"
check "status（on 後）有効表示を含む" "yes" "$(printf '%s' "$ST_ON" | grep -q '有効' && echo yes || echo no)"
check "status（on 後）API_TIMEOUT_MS を含む" "yes" "$(printf '%s' "$ST_ON" | grep -q 'API_TIMEOUT_MS' && echo yes || echo no)"
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" off >/dev/null 2>&1
ST_OFF="$(CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" status 2>&1)"
check "status（off 後）無効表示を含む" "yes" "$(printf '%s' "$ST_OFF" | grep -q '無効' && echo yes || echo no)"

# ── 引数無し/不正サブコマンド: usage を表示して exit 2。
reset
EC=0; CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" >/dev/null 2>&1 || EC=$?
check "引数無しで exit 2" "2" "$EC"
EC=0; CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" bogus >/dev/null 2>&1 || EC=$?
check "不正サブコマンドで exit 2" "2" "$EC"

# ── off（スプリント稼働中＝hooks 検出）: env を一切変更せずスキップし exit 0、警告を出す。
#    3キーも .hooks も残る（シナリオB＝スプリント注入分の削除を完全に防ぐ）。
reset
mkdir -p "$T/.claude"
echo '{"hooks":{"X":1},"env":{"API_TIMEOUT_MS":"300000","CLAUDE_ENABLE_STREAM_WATCHDOG":"1","CLAUDE_CODE_MAX_RETRIES":"10"}}' > "$LOCAL"
EC=0; OFF_OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" off 2>&1)" || EC=$?
check "off（稼働中）exit 0" "0" "$EC"
check "off（稼働中）API_TIMEOUT_MS が残る（削除しない）" "300000" "$(jq -r '.env.API_TIMEOUT_MS // "MISSING"' "$LOCAL")"
check "off（稼働中）CLAUDE_ENABLE_STREAM_WATCHDOG が残る" "1" "$(jq -r '.env.CLAUDE_ENABLE_STREAM_WATCHDOG // "MISSING"' "$LOCAL")"
check "off（稼働中）CLAUDE_CODE_MAX_RETRIES が残る" "10" "$(jq -r '.env.CLAUDE_CODE_MAX_RETRIES // "MISSING"' "$LOCAL")"
check "off（稼働中）env のキー数が3のまま" "3" "$(jq -r '.env | keys | length' "$LOCAL")"
check "off（稼働中）hooks.X も残る" "1" "$(jq -r '.hooks.X // "MISSING"' "$LOCAL")"
check "off（稼働中）stderr にスキップ警告を含む" "yes" "$(printf '%s' "$OFF_OUT" | grep -q 'スプリント稼働中' && echo yes || echo no)"

# ── on（スプリント稼働中＝hooks 検出）: 注入は行い hooks は保持、警告を出す。
reset
mkdir -p "$T/.claude"
echo '{"hooks":{"X":1}}' > "$LOCAL"
ON_OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on 2>&1)"
check "on（稼働中）3キーが注入される" "1" "$(jq -r '.env.CLAUDE_ENABLE_STREAM_WATCHDOG // "MISSING"' "$LOCAL")"
check "on（稼働中）env のキー数が3" "3" "$(jq -r '.env | keys | length' "$LOCAL")"
check "on（稼働中）hooks.X が保持される" "1" "$(jq -r '.hooks.X // "MISSING"' "$LOCAL")"
check "on（稼働中）stderr に警告を含む" "yes" "$(printf '%s' "$ON_OUT" | grep -q 'スプリント稼働中' && echo yes || echo no)"

# ── status（スプリント稼働中＝hooks 検出）: 出力に注記文字列を含む。
reset
mkdir -p "$T/.claude"
echo '{"hooks":{"X":1},"env":{"API_TIMEOUT_MS":"300000"}}' > "$LOCAL"
ST_ACT="$(CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" status 2>&1)"
check "status（稼働中）注記文字列を含む" "yes" "$(printf '%s' "$ST_ACT" | grep -q '表示中の値は sprint 由来の可能性あり' && echo yes || echo no)"

# ── status（hooks 無し＝非稼働）: 注記文字列を含まない（回帰）。
reset
CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on >/dev/null 2>&1
ST_INACT="$(CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" status 2>&1)"
check "status（非稼働）注記文字列を含まない" "no" "$(printf '%s' "$ST_INACT" | grep -q '表示中の値は sprint 由来の可能性あり' && echo yes || echo no)"

# ── 余分引数: on extra は usage 表示して exit 2。
reset
EC=0; CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" on extra >/dev/null 2>&1 || EC=$?
check "余分引数 'on extra' で exit 2" "2" "$EC"
EC=0; CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" off off >/dev/null 2>&1 || EC=$?
check "余分引数 'off off' で exit 2" "2" "$EC"
EC=0; CLAUDE_PROJECT_DIR="$T" bash "$SCRIPT" status x >/dev/null 2>&1 || EC=$?
check "余分引数 'status x' で exit 2" "2" "$EC"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
