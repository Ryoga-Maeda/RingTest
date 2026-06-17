#!/usr/bin/env bash
# tests/test_isolation.sh — M0 達成判定（P0-6）
# ゴール: 通常起動で全フックが副作用ゼロ。スプリント起動のみでフックが作動する。
set -euo pipefail

PASS=0
FAIL=0
ROOT="$(git rev-parse --show-toplevel)"
STATE_FILE="$ROOT/sprint/state.json"
GUARD="$ROOT/.claude/sprint/hooks/_guard.sh"

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_isolation.sh（M0 達成判定）==="

# --- シナリオ1: 通常起動（run_state=OFF）で副作用ゼロ ---
echo ""
echo "シナリオ1: 通常起動（run_state=OFF）"

# state.json の run_state=OFF をバックアップ・設定
original_state=$(cat "$STATE_FILE")
original_run_state=$(jq -r '.run_state' "$STATE_FILE")
trap 'echo "$original_state" > "$STATE_FILE"' EXIT
jq '.run_state = "OFF"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

# _guard.sh がフックを no-op にすること（"REACHED" が出力されない）
actual=$(bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
check "通常起動: _guard.sh が no-op" "" "$actual"

# state.json が変更されていないこと
state_after=$(cat "$STATE_FILE")
run_state_after=$(jq -r '.run_state' "$STATE_FILE")
check "通常起動: state.json の run_state が OFF のまま" "OFF" "$run_state_after"

# --- シナリオ2: スプリント起動（run_state=RUNNING）でフックが作動 ---
echo ""
echo "シナリオ2: スプリント起動（run_state=RUNNING）"

jq '.run_state = "RUNNING"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

# _guard.sh がフックを継続させること（"REACHED" が出力される）
actual=$(bash -c "source '$GUARD'; echo REACHED" 2>/dev/null || true)
check "スプリント起動: _guard.sh がフックを継続" "REACHED" "$actual"

# --- 後片付け：state.json を元の状態に戻す ---
echo "$original_state" > "$STATE_FILE"
run_state_restored=$(jq -r '.run_state' "$STATE_FILE")
check "後片付け: state.json を元の状態に復元" "$original_run_state" "$run_state_restored"

# --- P0-2 スキーマ検証 ---
echo ""
echo "P0-2: state.json スキーマ検証"

# jq でパースできること（set -e と競合しないよう || で終了コードを捕捉）
EXIT_JQ=0
jq empty "$STATE_FILE" 2>/dev/null || EXIT_JQ=$?
check "state.json が有効なJSON" "0" "$EXIT_JQ"

# 必須フィールドの存在確認
# 注: Human 承認は state.json ではなく sprint/gate_approvals.json に分離（§7.6）。
#     旧 gate_approval フィールドは廃止したため必須フィールドから除外する。
for field in sprint_id phase run_state started_at last_checkpoint contract tasks resilience resume_hint escalations_active escalations_archived_ref; do
  val=$(jq "has(\"$field\")" "$STATE_FILE" 2>/dev/null)
  check "state.json に $field フィールドが存在" "true" "$val"
done

# 使用量スキーマは撤去済み（移設分は .resilience へ）。
check "state.json に usage フィールドが無い（使用量撤去）" "false" \
  "$(jq 'has("usage")' "$STATE_FILE" 2>/dev/null)"

# 承認は分離ファイルで管理されていること（gate_approvals.json）
check "state.json に旧 gate_approval が無い（gate_approvals.json へ一本化）" "false" \
  "$(jq 'has("gate_approval")' "$STATE_FILE" 2>/dev/null)"

# --- P0-4 テンプレート存在確認 ---
echo ""
echo "P0-4: テンプレートファイル存在確認"

# §11.2 R-1: .claude/sprint/RULES.md (v1) は削除済み。V2 規律は L1 フレームワークヘッダに移転。
for f in "sprint/PRODUCT.md" "sprint/SPRINT.md" "sprint/checkpoint.md" "sprint/DECISIONS.md" ".claude/agents/_prefix/L1-framework-header.md"; do
  if [ -f "$ROOT/$f" ]; then
    check "$f が存在" "0" "0"
  else
    check "$f が存在" "0" "1"
  fi
done

# L1 フレームワークヘッダに V2 規律 R0〜R6 が含まれること (R3' は単語境界の都合上スキップし下で個別検査)
for r in R0 R1 R2 R3 R4 R5 R6; do
  if grep -qw "$r" "$ROOT/.claude/agents/_prefix/L1-framework-header.md" 2>/dev/null; then
    check "L1 フレームワークヘッダに $r が含まれる" "0" "0"
  else
    check "L1 フレームワークヘッダに $r が含まれる" "0" "1"
  fi
done

# R3' (改善フェーズのバグ再現テスト先行) も L1 ヘッダに含まれること
if grep -q "R3'" "$ROOT/.claude/agents/_prefix/L1-framework-header.md" 2>/dev/null; then
  check "L1 フレームワークヘッダに R3' が含まれる" "0" "0"
else
  check "L1 フレームワークヘッダに R3' が含まれる" "0" "1"
fi

# SPRINT.md に Sprint Contract セクションが存在すること
if grep -q "Sprint Contract" "$ROOT/sprint/SPRINT.md" 2>/dev/null; then
  check "SPRINT.md に Sprint Contract セクションが存在" "0" "0"
else
  check "SPRINT.md に Sprint Contract セクションが存在" "0" "1"
fi

# --- P0-5 ファイル存在確認 ---
echo ""
echo "P0-5: スクリプト・設定ファイル存在確認"

# §11.2 R-2a-2: scripts/sprint-runner.sh (v1) は削除済み。V2 は phase-advance.sh フック駆動。
for f in ".claude/settings.json" "scripts/phase-advance-eval.sh" "scripts/phase-advance-apply.sh"; do
  if [ -f "$ROOT/$f" ]; then
    check "$f が存在" "0" "0"
  else
    check "$f が存在" "0" "1"
  fi
done

# FR-1（設定分離）: フック登録は .claude/sprint/settings.json に隔離し、
# ルート .claude/settings.json はフック登録を持たずクリーンに保つ（二段隔離）。
if grep -q "session-start.sh" "$ROOT/.claude/sprint/settings.json" 2>/dev/null; then
  check "フック登録が .claude/sprint/settings.json に隔離されている" "0" "0"
else
  check "フック登録が .claude/sprint/settings.json に隔離されている" "0" "1"
fi
# DoD M-4（改訂）: 壊れた .claude/settings.json でも通常 claude 起動の「規律面」が無傷になるよう、
# 規律フック（PreToolUse/PostToolUse/Stop 等）はルート設定に置かず sprint/settings.json に隔離する。
# ルートに許可するのは、通常開発中もキャラの語り口を継続させる無害な SessionStart（persona-ambient）のみ。
# これは state.json に persona があるときだけ語り口を出す装飾で、判断・規律には影響せず、
# それ自体は失敗しても常に exit 0（フックは defensive）。SPRINT_PERSONA=off で無効化できる。
ROOT_HOOK_KEYS=$(jq -c '.hooks // {} | keys' "$ROOT/.claude/settings.json" 2>/dev/null)
check "M-4: ルート設定の hooks キーは SessionStart のみ（規律フック非搭載）" '["SessionStart"]' "$ROOT_HOOK_KEYS"
# 規律フック（PreToolUse/PostToolUse/Stop）がルートに無いこと（隔離の核）。
for ev in PreToolUse PostToolUse Stop; do
  if jq -e ".hooks.$ev" "$ROOT/.claude/settings.json" >/dev/null 2>&1; then
    check "M-4: ルート設定に規律フック $ev が無い" "no" "yes"
  else
    check "M-4: ルート設定に規律フック $ev が無い" "no" "no"
  fi
done
# ルートの SessionStart は persona-ambient のみ（規律スクリプトを忍ばせていない）。
if jq -e '[.hooks.SessionStart[].hooks[].command] | all(test("persona-ambient"))' \
     "$ROOT/.claude/settings.json" >/dev/null 2>&1; then
  check "M-4: ルート SessionStart は persona-ambient 専用（装飾のみ）" "yes" "yes"
else
  check "M-4: ルート SessionStart は persona-ambient 専用（装飾のみ）" "yes" "no"
fi

# §11.2 R-2a-2: V2 では phase-advance スクリプト群が実行可能であること
for s in phase-advance-eval.sh phase-advance-apply.sh phase-advance-eval-next-phase.sh phase-advance-eval-next-sub.sh; do
  if [ -x "$ROOT/scripts/$s" ]; then
    check "scripts/$s が実行可能" "0" "0"
  else
    check "scripts/$s が実行可能" "0" "1"
  fi
done

# ルート CLAUDE.md に R0〜R6 が含まれないこと（隔離確認）。
# -w（単語一致）で照合する: 部分一致だと「R18」「R100」等の無害な語が R1 に誤検知される
# （実例: R18 コンテンツ方針を書いた導入先 CLAUDE.md が誤 FAIL した）。
# 「R1)」「R1:」「（R1）」のような規律識別子は -w でも検出される。
# §11.2 R-1: V2 では R0/R6 を追加したため検査対象を拡張。
for r in R0 R1 R2 R3 R4 R5 R6; do
  if grep -qw "$r" "$ROOT/CLAUDE.md" 2>/dev/null; then
    check "ルートCLAUDE.md に $r が含まれない（隔離）" "0" "1"
  else
    check "ルートCLAUDE.md に $r が含まれない（隔離）" "0" "0"
  fi
done

# --- .gitignore 確認 ---
echo ""
echo ".gitignore 確認"
if grep -q ".claude/worktrees/" "$ROOT/.gitignore" 2>/dev/null; then
  check ".gitignore に .claude/worktrees/ エントリが存在" "0" "0"
else
  check ".gitignore に .claude/worktrees/ エントリが存在" "0" "1"
fi
# クラウドで cloud-kickoff が生成する一時設定の誤コミット防止（cloud-kickoff-hook-activation）
if grep -q ".claude/settings.local.json" "$ROOT/.gitignore" 2>/dev/null; then
  check ".gitignore に .claude/settings.local.json エントリが存在" "0" "0"
else
  check ".gitignore に .claude/settings.local.json エントリが存在" "0" "1"
fi

# --- IP-5: CLAUDE_CODE_AUTO_COMPACT_WINDOW の設定（主担当は第2の柱・二重定義禁止）---
echo ""
echo "IP-5: AUTO_COMPACT_WINDOW 設定"
check "sprint/settings.json に CLAUDE_CODE_AUTO_COMPACT_WINDOW が設定" "yes" \
  "$(jq -e '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$ROOT/.claude/sprint/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
check "ルート settings.json に同 env が無い（二重定義禁止）" "no" \
  "$(jq -e '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$ROOT/.claude/settings.json" >/dev/null 2>&1 && echo yes || echo no)"

# --- 結果 ---
echo ""
echo "================================"
echo "M0 判定結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "M0 ACHIEVED ✓" && exit 0 || echo "M0 NOT ACHIEVED ✗" && exit 1
