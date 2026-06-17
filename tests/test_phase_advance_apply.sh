#!/usr/bin/env bash
# tests/test_phase_advance_apply.sh
#
# scripts/phase-advance-apply.sh の単体テスト。
# §6.4 遷移表の全行・冪等性・improve_iteration++・phase_log.jsonl 追記・並列 atomic 性を検証する。
#
# 注意:
#   - apply は cwd 相対で sprint/state.json を読み書きする → 各ケースを一時ディレクトリで実行する
#   - eval-next-phase.sh / eval-next-sub.sh は state.json の triage.P1 / triage.P2,
#     sprint/BRIEF.md, sprint/IMPROVE.md, sprint/SPRINT.md, sprint/PRODUCT.md を参照する
#   - apply は同 dir に置かれた scripts/* を相対パスで呼ぶため、tmpdir に scripts symlink を張る
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
APPLY="$REPO_ROOT/scripts/phase-advance-apply.sh"

[ -x "$APPLY" ] || { echo "FAIL: $APPLY が実行可能ではありません"; exit 1; }

fail=0
pass=0

# 各ケース共通の tmp 環境を組み立てる:
#   $1: 一時ディレクトリ パス（呼び出し側で mktemp -d 済み）
setup_workdir() {
  local d="$1"
  mkdir -p "$d/sprint" "$d/scripts"
  # 注: apply -> eval-next-phase は scripts/plan-waves.sh を直接実行（bash 経由ではない）。
  # 元 repo の plan-waves.sh は 644 のため、テスト側で実体コピー + chmod +x して
  # apply の本来の DAG 判定が動作する状態で検証する。
  for s in phase-advance-apply.sh phase-advance-eval-next-phase.sh phase-advance-eval-next-sub.sh plan-waves.sh; do
    cp "$REPO_ROOT/scripts/$s" "$d/scripts/$s"
    chmod +x "$d/scripts/$s"
  done
}

# state.json の phase/sub_phase が期待値と一致するかを検査する
check_phase_sub() {
  local name="$1" expected_phase="$2" expected_sub="$3" state_file="$4"
  local got_phase got_sub
  got_phase=$(jq -r '.phase' "$state_file" 2>/dev/null || echo "<read-error>")
  got_sub=$(jq -r '.sub_phase' "$state_file" 2>/dev/null || echo "<read-error>")
  if [ "$got_phase" = "$expected_phase" ] && [ "$got_sub" = "$expected_sub" ]; then
    pass=$((pass+1)); echo "  PASS: $name"
  else
    fail=$((fail+1)); echo "  FAIL: $name (expect: $expected_phase/$expected_sub got: $got_phase/$got_sub)"
  fi
}

# apply を tmpdir で実行
run_apply() {
  local d="$1"
  (cd "$d" && bash "./scripts/phase-advance-apply.sh") >/dev/null 2>&1 || true
}

# ---- ケース1: CLARIFY/implement → DESIGN/implement ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{"CLARIFY_TO_DESIGN":true}}
JSON
: > "$tmpdir/sprint/PRODUCT.md"
run_apply "$tmpdir"
check_phase_sub "CLARIFY/implement -> DESIGN/implement (満たす)" "DESIGN" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース1b: CLARIFY/implement (ゲート未承認) → 不変 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{"CLARIFY_TO_DESIGN":false}}
JSON
: > "$tmpdir/sprint/PRODUCT.md"
run_apply "$tmpdir"
check_phase_sub "CLARIFY/implement (ゲート未承認) -> 不変" "CLARIFY" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース1c: CLARIFY/implement (PRODUCT.md なし) → 不変 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{"CLARIFY_TO_DESIGN":true}}
JSON
run_apply "$tmpdir"
check_phase_sub "CLARIFY/implement (PRODUCT.md なし) -> 不変" "CLARIFY" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース2: DESIGN/* (SPRINT.md 存在) → PLAN/(維持) ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"DESIGN","sub_phase":"implement"}
JSON
: > "$tmpdir/sprint/SPRINT.md"
run_apply "$tmpdir"
check_phase_sub "DESIGN/implement -> PLAN/implement" "PLAN" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース2b: DESIGN/improve → PLAN/improve (sub_phase 維持) ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"DESIGN","sub_phase":"improve"}
JSON
: > "$tmpdir/sprint/SPRINT.md"
run_apply "$tmpdir"
check_phase_sub "DESIGN/improve -> PLAN/improve" "PLAN" "improve" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース2c: DESIGN (SPRINT.md なし) → 不変 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"DESIGN","sub_phase":"implement"}
JSON
run_apply "$tmpdir"
check_phase_sub "DESIGN (SPRINT.md なし) -> 不変" "DESIGN" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース3: PLAN/* (contract.agreed=true, DAG 正常) → EXECUTE/(維持) ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
# tasks が空でも plan-waves.sh は exit 0 で {"waves":[]} を返す
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"PLAN","sub_phase":"implement","contract":{"agreed":true},"tasks":{}}
JSON
run_apply "$tmpdir"
check_phase_sub "PLAN/implement (agreed+DAG ok) -> EXECUTE/implement" "EXECUTE" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース3b: PLAN/* (contract.agreed=false) → 不変 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"PLAN","sub_phase":"implement","contract":{"agreed":false},"tasks":{}}
JSON
run_apply "$tmpdir"
check_phase_sub "PLAN (agreed=false) -> 不変" "PLAN" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース3c: PLAN/* (DAG 循環) → 不変 ----
# 循環依存を持つ tasks を state.json に書き込み、plan-waves.sh が exit 3 で失敗する状態を作る
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{
  "phase":"PLAN",
  "sub_phase":"implement",
  "contract":{"agreed":true},
  "tasks":{
    "task-a":{"status":"TODO","depends_on":["task-b"],"touches":["x"]},
    "task-b":{"status":"TODO","depends_on":["task-a"],"touches":["y"]}
  }
}
JSON
# DAG 循環を確認（plan-waves.sh が exit !=0 を返すこと）
( cd "$tmpdir" && bash ./scripts/plan-waves.sh >/dev/null 2>&1 )
plan_rc=$?
if [ "$plan_rc" = "0" ]; then
  fail=$((fail+1)); echo "  FAIL: pre-check plan-waves.sh が DAG 循環を検出していない (rc=$plan_rc)"
else
  pass=$((pass+1)); echo "  PASS: pre-check plan-waves.sh が DAG 循環を検出 (rc=$plan_rc)"
fi
run_apply "$tmpdir"
check_phase_sub "PLAN (DAG 循環) -> 不変" "PLAN" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース4: COMPLETE/implement → TRIAGE/triage (即時) ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"COMPLETE","sub_phase":"implement","improve_iteration":0}
JSON
run_apply "$tmpdir"
check_phase_sub "COMPLETE/implement -> TRIAGE/triage" "TRIAGE" "triage" "$tmpdir/sprint/state.json"
# improve_iteration は cur_sub("implement") -> new_sub("triage") の遷移で +1 される
iter=$(jq -r '.improve_iteration' "$tmpdir/sprint/state.json")
if [ "$iter" = "1" ]; then
  pass=$((pass+1)); echo "  PASS: COMPLETE/implement -> TRIAGE/triage で improve_iteration が 0 -> 1"
else
  fail=$((fail+1)); echo "  FAIL: COMPLETE/implement -> TRIAGE/triage で improve_iteration (got=$iter)"
fi
rm -rf "$tmpdir"

# ---- ケース5: TRIAGE/triage (BRIEF 存在 ∧ P1+P2=0) → COMPLETE/implement ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"TRIAGE","sub_phase":"triage","triage":{"P1":0,"P2":0},"improve_iteration":1}
JSON
: > "$tmpdir/sprint/BRIEF.md"
run_apply "$tmpdir"
check_phase_sub "TRIAGE/triage (P1+P2=0) -> COMPLETE/implement" "COMPLETE" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース6: TRIAGE/triage (BRIEF 存在 ∧ P1+P2>0 ∧ ゲート承認) → CLARIFY/improve, iter++ ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"TRIAGE","sub_phase":"triage","triage":{"P1":1,"P2":0},"improve_iteration":1,"gate_approvals":{"TRIAGE_TO_IMPROVE":true}}
JSON
: > "$tmpdir/sprint/BRIEF.md"
run_apply "$tmpdir"
check_phase_sub "TRIAGE/triage (P1>0+ゲート) -> CLARIFY/improve" "CLARIFY" "improve" "$tmpdir/sprint/state.json"
# improve_iteration は new_sub=improve なので +1 されない（apply 仕様: triage に切替時のみ +1）
iter=$(jq -r '.improve_iteration' "$tmpdir/sprint/state.json")
if [ "$iter" = "1" ]; then
  pass=$((pass+1)); echo "  PASS: TRIAGE->CLARIFY/improve で improve_iteration は不変 (triage 切替ではないため)"
else
  fail=$((fail+1)); echo "  FAIL: TRIAGE->CLARIFY/improve で improve_iteration (got=$iter, expect=1)"
fi
rm -rf "$tmpdir"

# ---- ケース6b: TRIAGE/triage (P>0, ゲート未承認) → 不変 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"TRIAGE","sub_phase":"triage","triage":{"P1":1,"P2":0},"improve_iteration":0,"gate_approvals":{"TRIAGE_TO_IMPROVE":false}}
JSON
: > "$tmpdir/sprint/BRIEF.md"
run_apply "$tmpdir"
check_phase_sub "TRIAGE/triage (P>0,ゲート未承認) -> 不変" "TRIAGE" "triage" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース6c: TRIAGE/triage (BRIEF.md なし) → 不変 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"TRIAGE","sub_phase":"triage","triage":{"P1":1,"P2":0},"improve_iteration":0,"gate_approvals":{"TRIAGE_TO_IMPROVE":true}}
JSON
run_apply "$tmpdir"
check_phase_sub "TRIAGE/triage (BRIEF なし) -> 不変" "TRIAGE" "triage" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース7: CLARIFY/improve (IMPROVE.md ∧ ゲート承認) → DESIGN/improve ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"CLARIFY","sub_phase":"improve","gate_approvals":{"IMPROVE_CLARIFY_TO_DESIGN":true}}
JSON
: > "$tmpdir/sprint/IMPROVE.md"
run_apply "$tmpdir"
check_phase_sub "CLARIFY/improve -> DESIGN/improve" "DESIGN" "improve" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース7b: CLARIFY/improve (ゲート未承認) → 不変 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"CLARIFY","sub_phase":"improve","gate_approvals":{"IMPROVE_CLARIFY_TO_DESIGN":false}}
JSON
: > "$tmpdir/sprint/IMPROVE.md"
run_apply "$tmpdir"
check_phase_sub "CLARIFY/improve (ゲート未承認) -> 不変" "CLARIFY" "improve" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース8: COMPLETE/improve (P1+P2>0, iter<3) → TRIAGE/triage, iter++ ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"COMPLETE","sub_phase":"improve","triage":{"P1":2,"P2":0},"improve_iteration":1}
JSON
run_apply "$tmpdir"
check_phase_sub "COMPLETE/improve (P>0,iter<3) -> TRIAGE/triage" "TRIAGE" "triage" "$tmpdir/sprint/state.json"
iter=$(jq -r '.improve_iteration' "$tmpdir/sprint/state.json")
if [ "$iter" = "2" ]; then
  pass=$((pass+1)); echo "  PASS: COMPLETE/improve -> TRIAGE/triage で improve_iteration 1 -> 2"
else
  fail=$((fail+1)); echo "  FAIL: COMPLETE/improve -> TRIAGE/triage で improve_iteration (got=$iter, expect=2)"
fi
rm -rf "$tmpdir"

# ---- ケース9: COMPLETE/improve (P>0, iter>=3) → ESCALATION/improve ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"COMPLETE","sub_phase":"improve","triage":{"P1":1,"P2":1},"improve_iteration":3}
JSON
run_apply "$tmpdir"
check_phase_sub "COMPLETE/improve (P>0,iter>=3) -> ESCALATION/improve" "ESCALATION" "improve" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース10: COMPLETE/improve (P1+P2=0) → COMPLETE/implement ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"COMPLETE","sub_phase":"improve","triage":{"P1":0,"P2":0},"improve_iteration":2}
JSON
run_apply "$tmpdir"
check_phase_sub "COMPLETE/improve (P=0) -> COMPLETE/implement" "COMPLETE" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース11: 冪等性 (CLARIFY/implement → DESIGN/implement 後の再 apply) ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{"CLARIFY_TO_DESIGN":true}}
JSON
: > "$tmpdir/sprint/PRODUCT.md"
run_apply "$tmpdir"     # 1 回目: CLARIFY -> DESIGN
run_apply "$tmpdir"     # 2 回目: DESIGN/implement で SPRINT.md なし → 不変であるべき
check_phase_sub "Idempotent: CLARIFY->DESIGN 後の再 apply は DESIGN/implement で不変" "DESIGN" "implement" "$tmpdir/sprint/state.json"
rm -rf "$tmpdir"

# ---- ケース12: phase_log.jsonl への追記検証 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"DESIGN","sub_phase":"implement"}
JSON
: > "$tmpdir/sprint/SPRINT.md"
run_apply "$tmpdir"
log="$tmpdir/sprint/phase_log.jsonl"
if [ ! -f "$log" ]; then
  fail=$((fail+1)); echo "  FAIL: phase_log.jsonl が生成されていない"
else
  lines=$(wc -l < "$log")
  if [ "$lines" = "1" ]; then
    pass=$((pass+1)); echo "  PASS: phase_log.jsonl に 1 行追記された"
  else
    fail=$((fail+1)); echo "  FAIL: phase_log.jsonl の行数 (got=$lines, expect=1)"
  fi
  # 追記内容の構造を確認
  logged_phase=$(jq -r '.phase' "$log" 2>/dev/null || echo "")
  logged_sub=$(jq -r '.sub_phase' "$log" 2>/dev/null || echo "")
  logged_ts=$(jq -r '.ts' "$log" 2>/dev/null || echo "")
  if [ "$logged_phase" = "PLAN" ] && [ "$logged_sub" = "implement" ] && [ -n "$logged_ts" ]; then
    pass=$((pass+1)); echo "  PASS: phase_log 記録内容 (phase=PLAN, sub_phase=implement, ts=*) 正常"
  else
    fail=$((fail+1)); echo "  FAIL: phase_log 記録内容 (phase=$logged_phase sub=$logged_sub ts=$logged_ts)"
  fi
fi
# 再 apply で行が増えないこと（DESIGN 後の PLAN/implement では SPRINT.md→tasks 必要だが今回は contract 未承認なので不変）
run_apply "$tmpdir"
lines_after=$(wc -l < "$log" 2>/dev/null || echo 0)
if [ "$lines_after" = "1" ]; then
  pass=$((pass+1)); echo "  PASS: 不変遷移時は phase_log.jsonl に追記されない"
else
  fail=$((fail+1)); echo "  FAIL: 不変遷移時に phase_log.jsonl に追記された (lines=$lines_after)"
fi
rm -rf "$tmpdir"

# ---- ケース13: state.json 不整合 → exit 1 ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
echo '{"sub_phase":"implement"}' > "$tmpdir/sprint/state.json"   # phase 欠落
( cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null 2>&1 )
rc=$?
if [ "$rc" = "1" ]; then
  pass=$((pass+1)); echo "  PASS: state.json 不整合 (phase 欠落) で exit 1"
else
  fail=$((fail+1)); echo "  FAIL: state.json 不整合で exit 1 を返さない (rc=$rc)"
fi
rm -rf "$tmpdir"

# ---- ケース14: state.json が存在しない → exit 0 (no-op) ----
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
rm -f "$tmpdir/sprint/state.json"
( cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null 2>&1 )
rc=$?
if [ "$rc" = "0" ]; then
  pass=$((pass+1)); echo "  PASS: state.json なしは no-op (exit 0)"
else
  fail=$((fail+1)); echo "  FAIL: state.json なしで exit !=0 (rc=$rc)"
fi
rm -rf "$tmpdir"

# ---- ケース15: 並列実行 (flock による atomic 性) ----
# 同一 state に対して 2 プロセスを同時起動し、flock により atomic に処理されることを確認。
# 確認項目:
#   (a) state.json が壊れない（valid JSON）
#   (b) 最終 phase/sub_phase が期待値で一意に確定する
#   (c) phase_log.jsonl の各行が valid JSON（書き込みが交錯して破損していない）
# 注: 両プロセスとも flock 前に「CLARIFY -> DESIGN」と評価しうるため、phase_log は
#     最大 2 行になりうる。flock の保証は「state.json と phase_log への書込が atomic」
#     であり、ログの重複追記は許容範囲（state は冪等な jq 変換なので壊れない）。
tmpdir=$(mktemp -d)
setup_workdir "$tmpdir"
cat > "$tmpdir/sprint/state.json" <<'JSON'
{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{"CLARIFY_TO_DESIGN":true}}
JSON
: > "$tmpdir/sprint/PRODUCT.md"

( cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null 2>&1 ) &
pid1=$!
( cd "$tmpdir" && bash ./scripts/phase-advance-apply.sh >/dev/null 2>&1 ) &
pid2=$!
wait "$pid1"; wait "$pid2"

# (a) state.json は壊れず有効な JSON
if jq -e '.phase' "$tmpdir/sprint/state.json" >/dev/null 2>&1; then
  pass=$((pass+1)); echo "  PASS: 並列 apply 後も state.json が valid JSON"
else
  fail=$((fail+1)); echo "  FAIL: 並列 apply 後に state.json が壊れた"
fi
# (b) 最終 phase/sub_phase が一意に確定
check_phase_sub "並列 apply 後の phase/sub_phase が一意確定" "DESIGN" "implement" "$tmpdir/sprint/state.json"
# (c) phase_log.jsonl の各行が valid JSON（書込が atomic で行が破損していない）
log="$tmpdir/sprint/phase_log.jsonl"
if [ ! -f "$log" ]; then
  fail=$((fail+1)); echo "  FAIL: 並列 apply で phase_log.jsonl が生成されていない"
else
  log_lines=$(wc -l < "$log")
  all_valid="true"
  while IFS= read -r line; do
    if [ -n "$line" ] && ! echo "$line" | jq -e '.phase, .sub_phase, .ts' >/dev/null 2>&1; then
      all_valid="false"; break
    fi
  done < "$log"
  if [ "$all_valid" = "true" ] && [ "$log_lines" -ge 1 ] && [ "$log_lines" -le 2 ]; then
    pass=$((pass+1)); echo "  PASS: phase_log.jsonl の各行が valid JSON (行数=$log_lines, 期待: 1 or 2)"
  else
    fail=$((fail+1)); echo "  FAIL: phase_log.jsonl 整合性異常 (行数=$log_lines, all_valid=$all_valid)"
  fi
fi
rm -rf "$tmpdir"

# ---- サマリ ----
echo ""
echo "Total: pass=$pass fail=$fail"
[ "$fail" = "0" ]
