#!/usr/bin/env bash
# tests/test_schema_contract.sh — FR-5/FR-6 スキーマ契約・stdout クリーン化の固定テスト
#
# 目的:
#   - FR-5: Claude Code 更新による matcher（string↔array）／フック登録スキーマのドリフトを
#           早期検知する（settings.json の静的契約 + validate-settings の負テスト）。
#   - FR-6: 各フックの stdout が「許可フィールドのみ／空」を返すことを実起動で固定する（M-6）。
set -uo pipefail
ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
expect(){ local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected='$e' got='$a')"; FAIL=$((FAIL+1)); fi; }

echo "=== test_schema_contract.sh（FR-5/FR-6）==="

# ---------- (A) settings.json の hooks 登録スキーマ（FR-5 ドリフト検知）----------
S="$ROOT_REPO/.claude/sprint/settings.json"
expect "[FR-5] settings.json が妥当な JSON" "ok" "$(jq empty "$S" 2>/dev/null && echo ok || echo ng)"

# 既知イベント名のみ（未知イベントへのドリフトを検出）
UNKNOWN_EVENTS=$(jq -r '
  ["SessionStart","PreToolUse","PostToolUse","Stop","SubagentStop","UserPromptSubmit","PreCompact","Notification","SessionEnd"] as $known
  | (.hooks // {}) | keys[] | select(($known|index(.))|not)' "$S" 2>/dev/null)
expect "[FR-5] hooks のイベント名が既知スキーマ内" "" "$UNKNOWN_EVENTS"

# matcher は string 型のみ（array へのドリフトを検出）
BAD_MATCHER=$(jq -r '[(.hooks // {}) | to_entries[] | .value[] | select(has("matcher") and ((.matcher|type)!="string"))] | length' "$S" 2>/dev/null)
expect "[FR-5] matcher は string 型のみ（array ドリフト無し）" "0" "$BAD_MATCHER"
# hooks[].type=command / command は string
BAD_TYPE=$(jq -r '[(.hooks // {}) | to_entries[] | .value[] | .hooks[] | select(.type!="command")] | length' "$S" 2>/dev/null)
expect "[FR-5] hooks[].type は command のみ" "0" "$BAD_TYPE"
BAD_CMD=$(jq -r '[(.hooks // {}) | to_entries[] | .value[] | .hooks[] | select((.command|type)!="string")] | length' "$S" 2>/dev/null)
expect "[FR-5] hooks[].command は string のみ" "0" "$BAD_CMD"

# ---------- (B) validate-settings の負テスト（FR-5: 壊れた/ドリフトした設定を弾く）----------
TV=$(mktemp -d)
# matcher を array にドリフトさせた設定 → 現行スキーマ非適合で NG になるべき
cat > "$TV/settings.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": ["Write","Edit"], "hooks": [ { "type":"command","command":"x" } ] } ] } }
EOF
if bash "$ROOT_REPO/scripts/validate-settings.sh" "$TV/settings.json" >/dev/null 2>&1; then
  expect "[FR-5] matcher=array のドリフトを validate-settings が弾く" "NG" "OK"
else
  expect "[FR-5] matcher=array のドリフトを validate-settings が弾く" "NG" "NG"
fi
# 不正 JSON も弾く
printf 'BROKEN{' > "$TV/bad.json"
if bash "$ROOT_REPO/scripts/validate-settings.sh" "$TV/bad.json" >/dev/null 2>&1; then
  expect "[FR-5] 不正 JSON を validate-settings が弾く" "NG" "OK"
else
  expect "[FR-5] 不正 JSON を validate-settings が弾く" "NG" "NG"
fi
rm -rf "$TV"

# ---------- (C) フック出力の許可フィールド検証ロジック（M-6 検出能力）----------
# Claude Code のフック stdout 許可トップレベルキー（現行）。これ以外が出たら "dirty"。
ALLOWED="continue stopReason suppressOutput decision reason systemMessage hookSpecificOutput"
keys_verdict() {
  local out="$1"
  [ -z "$out" ] && { echo "empty"; return; }
  echo "$out" | jq -e . >/dev/null 2>&1 || { echo "text"; return; }
  [ "$(echo "$out" | jq -r 'type' 2>/dev/null)" = "object" ] || { echo "text"; return; }
  local bad
  bad=$(echo "$out" | jq -r --arg a "$ALLOWED" '($a|split(" ")) as $al | keys[] as $k | select(($al|index($k))|not) | $k' 2>/dev/null | paste -sd, -)
  if [ -z "$bad" ]; then echo "clean"; else echo "dirty:$bad"; fi
}
# 負テスト: 許可外キーを確実に検出できる（検出能力の固定）
expect "[M-6] 許可外トップレベルキーを検出する" "dirty:evilField" "$(keys_verdict '{"hookSpecificOutput":{},"evilField":1}')"
expect "[M-6] 許可フィールドのみは clean" "clean" "$(keys_verdict '{"hookSpecificOutput":{"x":1}}')"
expect "[M-6] 空出力は empty" "empty" "$(keys_verdict '')"

# ---------- (D) 各フックを実起動して stdout 契約を固定（FR-6）----------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/sprint/hooks" "$T/sprint" "$T/scripts"
for h in _guard.sh _state.sh _push.sh _control_commit.sh pre-task.sh post-task.sh on-stop.sh session-start.sh; do
  cp "$ROOT_REPO/.claude/sprint/hooks/$h" "$T/.claude/sprint/hooks/" 2>/dev/null || true
done
# §11.2 R-2b: scripts/gen-checkpoint.sh は削除済み (on-stop.sh にインライン化)
cp -r "$ROOT_REPO/.claude/sprint/policy" "$T/.claude/sprint/" 2>/dev/null || true
mk_state() {
  cat > "$T/sprint/state.json" <<'EOF'
{ "sprint_id":"s","phase":"EXECUTE","run_state":"RUNNING",
  "resilience":{"consecutive_tool_failures":0,"persist_failed":false,"persist_failed_branches":[]},
  "resume_hint":{"current_task":"t1","read_first":[],"next_action":"継続"},
  "tasks":{"t1":{"status":"IN_PROGRESS","failure_count":0,"tdd_phase":"RED"}} }
EOF
}

# pre-task allow（無関係ツール）→ stdout 空
mk_state
OUT=$(printf '%s' '{"tool_name":"Read","tool_input":{}}' | CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/sprint/hooks/pre-task.sh" 2>/dev/null)
expect "[FR-6] pre-task allow は stdout 空" "empty" "$(keys_verdict "$OUT")"

# pre-task deny（保護対象 hooks への Write→self_protect で deny）→ 許可フィールドのみ
mk_state
OUT=$(printf '%s' '{"tool_name":"Write","tool_input":{"file_path":".claude/sprint/hooks/on-stop.sh"}}' | CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/sprint/hooks/pre-task.sh" 2>/dev/null)
expect "[FR-6] pre-task deny は許可フィールドのみ（hookSpecificOutput）" "clean" "$(keys_verdict "$OUT")"
expect "[FR-6] pre-task deny は PreToolUse の hookSpecificOutput" "PreToolUse" "$(echo "$OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)"

# post-task → stdout 空（許可フィールド外を出さない）
mk_state
OUT=$(printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"x"}}' | CLAUDE_PROJECT_DIR="$T" SPRINT_USAGE_PCT=10 bash "$T/.claude/sprint/hooks/post-task.sh" 2>/dev/null)
expect "[FR-6] post-task は stdout 空" "empty" "$(keys_verdict "$OUT")"

# on-stop 通常終了（使用量に余裕・RUNNING）→ stdout 空（ログは stderr）
mk_state
OUT=$(CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/sprint/hooks/on-stop.sh" 2>/dev/null)
expect "[FR-6] on-stop 通常終了は stdout 空" "empty" "$(keys_verdict "$OUT")"

# session-start → additionalContext 相当の素テキスト（JSON でない＝許容）
mk_state
OUT=$(CLAUDE_PROJECT_DIR="$T" bash "$T/.claude/sprint/hooks/session-start.sh" 2>/dev/null)
V=$(keys_verdict "$OUT")
expect "[FR-6] session-start は素テキスト/空（許可フィールド逸脱なし）" "yes" "$([ "$V" = "text" ] || [ "$V" = "empty" ] || [ "$V" = "clean" ] && echo yes || echo no)"

# ---------- (E) state スキーマ契約: schema_version / resume_hint.in_flight（PT1-6）----------
SEED="$ROOT_REPO/sprint/state.json"
expect "[PT1-6] seed state.json が妥当な JSON" "ok" "$(jq empty "$SEED" 2>/dev/null && echo ok || echo ng)"
expect "[PT1-6] schema_version が 2 以上" "yes" "$(jq -e '(.schema_version // 0) >= 2' "$SEED" >/dev/null 2>&1 && echo yes || echo no)"
expect "[PT3] schema_version が 3 以上（タスクローカル状態）" "yes" "$(jq -e '(.schema_version // 0) >= 3' "$SEED" >/dev/null 2>&1 && echo yes || echo no)"
expect "[PT1-6] resume_hint.in_flight が配列" "array" "$(jq -r '.resume_hint.in_flight | type' "$SEED" 2>/dev/null)"
# 後方互換: schema_version 欠落（v1 相当）でも読み手が壊れない（欠落は v1 とみなす）
expect "[PT1-6] schema_version 欠落は v1 とみなせる（既定0→欠落許容）" "1" "$(echo '{"resume_hint":{}}' | jq -r '.schema_version // 1')"

# ---------- (F) run_state 集合の契約（使用量中断・再開の撤去）----------
# 新集合: OFF / RUNNING / COMPLETE / ABORTED。CHECKPOINTING / SUSPENDED は廃止された。
SEED_RS=$(jq -r '.run_state // "OFF"' "$SEED" 2>/dev/null)
expect "[run_state] seed の run_state が新集合内（OFF/RUNNING/COMPLETE/ABORTED）" "yes" \
  "$(case "$SEED_RS" in OFF|RUNNING|COMPLETE|ABORTED) echo yes;; *) echo no;; esac)"
# 使用量スキーマは撤去されている（移設分は .resilience へ）。
expect "[schema] seed に .usage が存在しない（撤去済み）" "null" "$(jq -r '.usage // "null" | if .=="null" then "null" else "exists" end' "$SEED" 2>/dev/null)"
expect "[schema] seed に .resilience.consecutive_tool_failures がある（移設）" "yes" \
  "$(jq -e 'has("resilience") and (.resilience | has("consecutive_tool_failures"))' "$SEED" >/dev/null 2>&1 && echo yes || echo no)"
# 撤去フィールドが seed に残っていないこと（grep 相当の機械照合）。
for f in consumed_pct reset_at block_new_tasks checkpoint_recommended just_resumed; do
  expect "[schema] seed に .usage.$f が残っていない" "no" \
    "$(jq -e --arg f "$f" '(.usage // {}) | has($f)' "$SEED" >/dev/null 2>&1 && echo yes || echo no)"
done

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
