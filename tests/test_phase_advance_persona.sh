#!/usr/bin/env bash
# tests/test_phase_advance_persona.sh — §10 キャラクター人格の next-action 注入契約
#
# 検証項目:
#   - phase-advance-eval.sh の出力先頭に persona compact ブロックが含まれる
#     (Orchestrator が次手プロンプトを通じて語り口を再接地できる)
#   - persona 未設定なら persona ブロックが含まれない（no-op）
#   - SPRINT_PERSONA=off なら persona ブロックが含まれない
#   - persona.muted=true なら persona ブロックが含まれない
#   - compact 形式である（rich のセリフ例は含まない＝バイト予算保護）
#   - 次手 (clarifier 起動指示等) 本文は persona ブロックの後にきちんと出る
set -uo pipefail
PASS=0; FAIL=0
ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check(){ local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected='$e' got='$a')"; FAIL=$((FAIL+1)); fi; }

echo "=== test_phase_advance_persona.sh ==="

setup_env() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/sprint" "$d/.claude/sprint/hooks" "$d/scripts"
  cp "$ROOT_REPO/.claude/sprint/personas.json" "$d/.claude/sprint/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_persona.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_state.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_control_commit.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_push.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/scripts/phase-advance-eval.sh" "$d/scripts/"
  printf '%s\n' "$d"
}

# 既知の persona を state に設置する補助 (CLARIFY/implement, PRODUCT.md 無し ＝ clarifier 起動指示)
seed_state_with_persona() {
  local d="$1"
  cat > "$d/sprint/state.json" <<'JSON'
{
  "phase": "CLARIFY",
  "sub_phase": "implement",
  "contract": {"agreed": false},
  "resume_hint": {"in_flight": []},
  "persona": {
    "id": "spark",
    "name": "スパークにゃん",
    "style": "明るく短く・…にゃ で終わる",
    "first_person": "あたし",
    "address": "プロデューサーさん",
    "speech": {
      "endings": ["…にゃ", "だにゃ"],
      "tics": ["せーのっ"]
    },
    "examples": [
      {"on": "進捗報告", "line": "T1 を実装したよ、にゃ。"}
    ]
  }
}
JSON
}

# ---------- (A) persona 設定済み → 次手プロンプト先頭に compact ブロックが含まれる ----------
D=$(setup_env)
seed_state_with_persona "$D"
OUT=$(CLAUDE_PROJECT_DIR="$D" bash -c "cd '$D' && bash scripts/phase-advance-eval.sh 2>/dev/null" || true)
check "[A] 出力に『オーケストレーター人格』見出しが含まれる" "yes" \
  "$(echo "$OUT" | grep -q 'オーケストレーター人格' && echo yes || echo no)"
check "[A] 出力に persona 名 (スパークにゃん) が含まれる" "yes" \
  "$(echo "$OUT" | grep -q 'スパークにゃん' && echo yes || echo no)"
# compact なのでセリフ例は含まれない (バイト予算保護)
check "[A] 出力にセリフ例が含まれない (compact 形式)" "yes" \
  "$(echo "$OUT" | grep -q 'セリフ例' && echo no || echo yes)"
# persona ブロックが next-action (clarifier 起動指示) より前に来る
PERSONA_LINE=$(echo "$OUT" | grep -n 'オーケストレーター人格' | head -1 | cut -d: -f1)
NEXT_LINE=$(echo "$OUT" | grep -n 'clarifier サブエージェントを起動' | head -1 | cut -d: -f1)
if [ -n "$PERSONA_LINE" ] && [ -n "$NEXT_LINE" ]; then
  check "[A] persona ブロックが next-action より前にある" "yes" \
    "$([ "$PERSONA_LINE" -lt "$NEXT_LINE" ] && echo yes || echo no)"
else
  check "[A] persona ブロックが next-action より前にある" "yes" "no"
fi
# next-action 本文 (clarifier 起動指示) が消えていない
check "[A] next-action (clarifier 起動指示) が末尾に残る" "yes" \
  "$(echo "$OUT" | grep -q 'clarifier サブエージェントを起動' && echo yes || echo no)"
rm -rf "$D"

# ---------- (B) persona 未設定 → persona ブロック無し・next-action は残る ----------
D=$(setup_env)
cat > "$D/sprint/state.json" <<'JSON'
{
  "phase": "CLARIFY",
  "sub_phase": "implement",
  "contract": {"agreed": false},
  "resume_hint": {"in_flight": []},
  "persona": null
}
JSON
OUT=$(CLAUDE_PROJECT_DIR="$D" bash -c "cd '$D' && bash scripts/phase-advance-eval.sh 2>/dev/null" || true)
check "[B] persona 未設定なら『オーケストレーター人格』見出しが出ない" "yes" \
  "$(echo "$OUT" | grep -q 'オーケストレーター人格' && echo no || echo yes)"
check "[B] persona 未設定でも next-action は出る" "yes" \
  "$(echo "$OUT" | grep -q 'clarifier サブエージェントを起動' && echo yes || echo no)"
rm -rf "$D"

# ---------- (C) SPRINT_PERSONA=off → persona ブロック無し ----------
D=$(setup_env)
seed_state_with_persona "$D"
OUT=$(CLAUDE_PROJECT_DIR="$D" SPRINT_PERSONA=off bash -c "cd '$D' && bash scripts/phase-advance-eval.sh 2>/dev/null" || true)
check "[C] SPRINT_PERSONA=off で persona ブロックが出ない" "yes" \
  "$(echo "$OUT" | grep -q 'オーケストレーター人格' && echo no || echo yes)"
check "[C] SPRINT_PERSONA=off でも next-action は出る" "yes" \
  "$(echo "$OUT" | grep -q 'clarifier サブエージェントを起動' && echo yes || echo no)"
rm -rf "$D"

# ---------- (D) persona.muted=true → persona ブロック無し ----------
D=$(setup_env)
seed_state_with_persona "$D"
jq '.persona.muted = true' "$D/sprint/state.json" > "$D/sprint/state.json.tmp" && mv "$D/sprint/state.json.tmp" "$D/sprint/state.json"
OUT=$(CLAUDE_PROJECT_DIR="$D" bash -c "cd '$D' && bash scripts/phase-advance-eval.sh 2>/dev/null" || true)
check "[D] persona.muted=true で persona ブロックが出ない" "yes" \
  "$(echo "$OUT" | grep -q 'オーケストレーター人格' && echo no || echo yes)"
check "[D] persona.muted=true でも next-action は出る" "yes" \
  "$(echo "$OUT" | grep -q 'clarifier サブエージェントを起動' && echo yes || echo no)"
rm -rf "$D"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
