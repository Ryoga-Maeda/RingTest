#!/usr/bin/env bash
# tests/test_phase_advance.sh — scripts/phase-advance-eval.sh の単体テスト（T-A.9）
#
# 検証観点:
#   1. 各 phase / sub_phase の入力に対し期待される指示文が出力されること
#   2. 同一 state を 5 連続実行しても出力が一致すること（冪等性）
#   3. R1 担保: 出力に「state.json.phase を ... へ更新」「state.json.sub_phase を ... へ更新」
#      の文字列を絶対に含まないこと
#
# 設計:
#   - 一時ディレクトリで sprint/state.json を ad-hoc 生成
#   - scripts/plan-waves.sh はテスト用に tmpdir/scripts/ にスタブ配置してシャドウ
#     （phase-advance-eval.sh は cwd 相対で `bash scripts/plan-waves.sh` を呼ぶ）
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EVAL_SCRIPT="$REPO_ROOT/scripts/phase-advance-eval.sh"

[ -x "$EVAL_SCRIPT" ] || { echo "FAIL: phase-advance-eval.sh not executable: $EVAL_SCRIPT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq が必要"; exit 1; }

fail=0
pass=0

# ------- ヘルパ -------

# tmpdir に sprint/state.json と必要ファイルを準備
# args: tmpdir state_json files...
#   files... は以下のキーワード列:
#     --product / --sprint / --findings / --brief / --improve
#     --plan-waves-stub-ok   : scripts/plan-waves.sh を exit 0 でスタブ
#     --plan-waves-stub-cycle: scripts/plan-waves.sh を「DAG 循環(cycle)」を吐いて exit 1 でスタブ
setup_tmp() {
  local tmpdir="$1"
  local state="$2"
  shift 2
  mkdir -p "$tmpdir/sprint"
  echo "$state" > "$tmpdir/sprint/state.json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --product)  : > "$tmpdir/sprint/PRODUCT.md" ;;
      --sprint)   : > "$tmpdir/sprint/SPRINT.md" ;;
      --findings) : > "$tmpdir/sprint/IMPROVE_FINDINGS.md" ;;
      --brief)    : > "$tmpdir/sprint/IMPROVE_BRIEF.md" ;;
      --improve)  : > "$tmpdir/sprint/IMPROVE.md" ;;
      --plan-waves-stub-ok)
        mkdir -p "$tmpdir/scripts"
        cat > "$tmpdir/scripts/plan-waves.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"waves":[]}'
exit 0
EOF
        chmod +x "$tmpdir/scripts/plan-waves.sh"
        ;;
      --plan-waves-stub-cycle)
        mkdir -p "$tmpdir/scripts"
        cat > "$tmpdir/scripts/plan-waves.sh" <<'EOF'
#!/usr/bin/env bash
echo "plan-waves: cycle detected among: task-a, task-b" >&2
exit 1
EOF
        chmod +x "$tmpdir/scripts/plan-waves.sh"
        ;;
    esac
    shift
  done
}

# 1 ケース実行: name / expected_substr / state_json / [setup_flags...]
# expected_substr は複数（カンマで区切る "AAA||BBB" 形式）に未対応。
# 複数 expected が必要なケースは run_case_multi を使う。
run_case() {
  local name="$1" expected="$2" state="$3"
  shift 3
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_tmp "$tmpdir" "$state" "$@"

  local out
  out=$(cd "$tmpdir" && bash "$EVAL_SCRIPT" 2>&1 || true)

  local case_ok=1

  if ! echo "$out" | grep -qF "$expected"; then
    case_ok=0
    echo "  FAIL: $name (期待文字列 '$expected' を含まず)"
    echo "    --- 実出力 ---"
    echo "$out" | sed 's/^/    /'
    echo "    --------------"
  fi

  # R1 担保: state.json.phase / sub_phase を更新する旨の文言があれば違反
  if echo "$out" | grep -qE 'state\.json\.(phase|sub_phase) を'; then
    case_ok=0
    echo "  FAIL: $name (R1 違反: state.json への書込指示文を検出)"
    echo "    --- 実出力 ---"
    echo "$out" | sed 's/^/    /'
    echo "    --------------"
  fi

  if [ "$case_ok" = "1" ]; then
    pass=$((pass+1))
    echo "  PASS: $name"
  else
    fail=$((fail+1))
  fi

  rm -rf "$tmpdir"
}

# 複数の期待部分文字列を検証するケース（全て含まれること）
# name / "exp1|exp2|exp3" / state_json / [setup_flags...]
run_case_multi() {
  local name="$1" expected="$2" state="$3"
  shift 3
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_tmp "$tmpdir" "$state" "$@"

  local out
  out=$(cd "$tmpdir" && bash "$EVAL_SCRIPT" 2>&1 || true)

  local case_ok=1
  local IFS_BAK="$IFS"
  IFS='|'
  for exp in $expected; do
    if ! echo "$out" | grep -qF "$exp"; then
      case_ok=0
      echo "  FAIL: $name (期待文字列 '$exp' を含まず)"
    fi
  done
  IFS="$IFS_BAK"

  if echo "$out" | grep -qE 'state\.json\.(phase|sub_phase) を'; then
    case_ok=0
    echo "  FAIL: $name (R1 違反: state.json への書込指示文を検出)"
  fi

  if [ "$case_ok" = "1" ]; then
    pass=$((pass+1))
    echo "  PASS: $name"
  else
    echo "    --- 実出力 ---"
    echo "$out" | sed 's/^/    /'
    echo "    --------------"
    fail=$((fail+1))
  fi

  rm -rf "$tmpdir"
}

# 「含まないこと」を検証するケース（NG 文字列を含んだら FAIL）
# name / expected_substr / ng_substr / state_json / [setup_flags...]
run_case_with_ng() {
  local name="$1" expected="$2" ng="$3" state="$4"
  shift 4
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_tmp "$tmpdir" "$state" "$@"

  local out
  out=$(cd "$tmpdir" && bash "$EVAL_SCRIPT" 2>&1 || true)

  local case_ok=1

  if ! echo "$out" | grep -qF "$expected"; then
    case_ok=0
    echo "  FAIL: $name (期待文字列 '$expected' を含まず)"
  fi

  if echo "$out" | grep -qF "$ng"; then
    case_ok=0
    echo "  FAIL: $name (NG 文字列 '$ng' を含む)"
  fi

  if echo "$out" | grep -qE 'state\.json\.(phase|sub_phase) を'; then
    case_ok=0
    echo "  FAIL: $name (R1 違反: state.json への書込指示文を検出)"
  fi

  if [ "$case_ok" = "1" ]; then
    pass=$((pass+1))
    echo "  PASS: $name"
  else
    echo "    --- 実出力 ---"
    echo "$out" | sed 's/^/    /'
    echo "    --------------"
    fail=$((fail+1))
  fi

  rm -rf "$tmpdir"
}

# ------- 個別ケース -------

echo "[phase-advance-eval.sh 単体テスト]"

# Case 1: CLARIFY 直後（PRODUCT.md なし）
run_case "C1: CLARIFY 直後（PRODUCT.md なし）" "clarifier" \
  '{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{}}'

# Case 2: CLARIFY / PRODUCT.md あり / gate=false
run_case "C2: CLARIFY / PRODUCT.md あり / gate=false" "AskUserQuestion" \
  '{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{}}' --product

# Case 3: CLARIFY / PRODUCT.md あり / gate=true
#   - 出力に "designer" を含む
#   - 出力に "state.json.phase" の文字列を含まない（NG 検査）
run_case_with_ng "C3: CLARIFY / PRODUCT.md あり / gate=true" "designer" "state.json.phase" \
  '{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{"CLARIFY_TO_DESIGN":true}}' --product

# Case 4: DESIGN（SPRINT.md なし）
run_case "C4: DESIGN（SPRINT.md なし）" "designer" \
  '{"phase":"DESIGN","sub_phase":"implement","gate_approvals":{}}'

# Case 5: PLAN / agreed=true / DAG 循環あり（スタブ）
run_case_multi "C5: PLAN / agreed=true / DAG 循環あり" "DAG 循環|decomposer" \
  '{"phase":"PLAN","sub_phase":"implement","contract":{"agreed":true},"gate_approvals":{}}' \
  --plan-waves-stub-cycle

# Case 6: PLAN / agreed=true / DAG 健全
run_case "C6: PLAN / agreed=true / DAG 健全" "executor" \
  '{"phase":"PLAN","sub_phase":"implement","contract":{"agreed":true},"gate_approvals":{}}' \
  --plan-waves-stub-ok

# Case 7: COMPLETE / sub_phase=implement
run_case "C7: COMPLETE / sub_phase=implement" "bug-hunter" \
  '{"phase":"COMPLETE","sub_phase":"implement","gate_approvals":{}}'

# Case 8: TRIAGE / FINDINGS なし
run_case "C8: TRIAGE / FINDINGS なし" "bug-hunter" \
  '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{}}'

# Case 9: TRIAGE / FINDINGS あり・BRIEF なし
run_case "C9: TRIAGE / FINDINGS あり・BRIEF なし" "investigator" \
  '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{}}' --findings

# Case 10: TRIAGE / BRIEF あり・P1+P2=0
run_case "C10: TRIAGE / BRIEF あり・P1+P2=0" "completer" \
  '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{},"triage_artifacts":{"p1_count":0,"p2_count":0}}' \
  --findings --brief

# Case 11: COMPLETE / sub_phase=improve / P1+P2>0 / improve_iteration=3
run_case "C11: COMPLETE / improve / iter=3 / 残存あり" "escalation-mgr" \
  '{"phase":"COMPLETE","sub_phase":"improve","gate_approvals":{},"triage_artifacts":{"p1_count":1,"p2_count":2},"improve_iteration":3}'

# Case 12: 同一 state で 5 連続呼出 → 出力一致（冪等性）
echo "  - C12: 冪等性（5 連続呼出で出力一致）"
{
  tmpdir=$(mktemp -d)
  setup_tmp "$tmpdir" \
    '{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{"CLARIFY_TO_DESIGN":true}}' \
    --product
  first=$(cd "$tmpdir" && bash "$EVAL_SCRIPT" 2>&1 || true)
  all_match=1
  for i in 2 3 4 5; do
    cur=$(cd "$tmpdir" && bash "$EVAL_SCRIPT" 2>&1 || true)
    if [ "$cur" != "$first" ]; then
      all_match=0
      echo "    FAIL: 第 $i 回呼出の出力が初回と一致しない"
      echo "      first: $first"
      echo "      curr : $cur"
    fi
  done
  if echo "$first" | grep -qE 'state\.json\.(phase|sub_phase) を'; then
    all_match=0
    echo "    FAIL: C12 R1 違反検出"
  fi
  if [ "$all_match" = "1" ]; then
    pass=$((pass+1))
    echo "  PASS: C12 冪等性"
  else
    fail=$((fail+1))
    echo "  FAIL: C12 冪等性"
  fi
  rm -rf "$tmpdir"
}

# Case 13: R1 担保（全ケース横断）
# 上で各ケース実行時に R1 違反検査済みだが、改めて代表的なフェーズすべてで
# 出力に「state.json.phase を / state.json.sub_phase を」が一度も現れないことを確認する。
echo "  - C13: R1 担保（代表フェーズ横断検査）"
{
  r1_ok=1
  # 検査するシナリオ群
  declare -a R1_STATES=(
    '{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{}}'
    '{"phase":"CLARIFY","sub_phase":"implement","gate_approvals":{"CLARIFY_TO_DESIGN":true}}'
    '{"phase":"DESIGN","sub_phase":"implement","gate_approvals":{}}'
    '{"phase":"PLAN","sub_phase":"implement","contract":{"agreed":false},"gate_approvals":{}}'
    '{"phase":"PLAN","sub_phase":"implement","contract":{"agreed":true},"gate_approvals":{}}'
    '{"phase":"EXECUTE","sub_phase":"implement","gate_approvals":{},"resume_hint":{"in_flight":[]}}'
    '{"phase":"EXECUTE","sub_phase":"implement","gate_approvals":{},"resume_hint":{"in_flight":["t-1"]}}'
    '{"phase":"VERIFY","sub_phase":"implement","gate_approvals":{}}'
    '{"phase":"INTEGRATE","sub_phase":"implement","gate_approvals":{}}'
    '{"phase":"COMPLETE","sub_phase":"implement","gate_approvals":{}}'
    '{"phase":"COMPLETE","sub_phase":"improve","gate_approvals":{},"triage_artifacts":{"p1_count":1,"p2_count":2},"improve_iteration":3}'
    '{"phase":"COMPLETE","sub_phase":"improve","gate_approvals":{},"triage_artifacts":{"p1_count":1,"p2_count":2},"improve_iteration":1}'
    '{"phase":"COMPLETE","sub_phase":"improve","gate_approvals":{},"triage_artifacts":{"p1_count":0,"p2_count":0},"improve_iteration":1}'
    '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{}}'
    '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{}}'
    '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{},"triage_artifacts":{"p1_count":0,"p2_count":0}}'
    '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{},"triage_artifacts":{"p1_count":1,"p2_count":2}}'
    '{"phase":"TRIAGE","sub_phase":"triage","gate_approvals":{"TRIAGE_TO_IMPROVE":true},"triage_artifacts":{"p1_count":1,"p2_count":2}}'
    '{"phase":"ESCALATION","sub_phase":"implement","gate_approvals":{}}'
  )
  for s in "${R1_STATES[@]}"; do
    tmpdir=$(mktemp -d)
    setup_tmp "$tmpdir" "$s" --product --sprint --findings --brief --improve --plan-waves-stub-ok
    out=$(cd "$tmpdir" && bash "$EVAL_SCRIPT" 2>&1 || true)
    if echo "$out" | grep -qE 'state\.json\.(phase|sub_phase) を'; then
      r1_ok=0
      echo "    FAIL: R1 違反 phase=$s"
      echo "      out: $out"
    fi
    rm -rf "$tmpdir"
  done
  if [ "$r1_ok" = "1" ]; then
    pass=$((pass+1))
    echo "  PASS: C13 R1 担保"
  else
    fail=$((fail+1))
    echo "  FAIL: C13 R1 担保"
  fi
}

echo "[結果] PASS=$pass FAIL=$fail"
[ "$fail" = "0" ]
