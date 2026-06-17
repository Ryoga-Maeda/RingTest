#!/usr/bin/env bash
# scripts/phase-advance-eval.sh — フェーズ評価（純関数・指示文生成）
#
# 目的:
#   sprint/state.json を読み、「Orchestrator が次に実行すべき一手」を 1 メッセージとして
#   標準出力へ書き出す純関数。state.json への書き込みは一切行わない（apply 側の責務）。
#   同じ state なら同じ出力を返す（冪等）。
#
# 呼び出し:
#   scripts/phase-advance-eval.sh > /tmp/next-instruction.txt
#
# 入力:
#   - 引数なし、環境変数なし
#   - 読込: sprint/state.json（必須）, sprint/SPRINT.md, sprint/PRODUCT.md,
#           sprint/IMPROVE_BRIEF.md, sprint/IMPROVE_FINDINGS.md（任意）
#
# 出力:
#   stdout: Orchestrator への指示文（1 メッセージ）
#   exit code: 0=正常 / 1=state.json 不整合
#
# 責務分割:
#   - phase / sub_phase の書換は行わない（T-A.2 phase-advance-apply.sh が担う）
#   - 指示文には「state.json を更新せよ」と書かない（apply 済みを前提）
#   - 代わりに「<agent> を起動せよ」だけを書く
#
# 拡張 (T-B.9):
#   - subagent_health[<agent>].quarantine_until が現在時刻より未来なら
#     bypass 経路の指示を出力する（投入対象のサブエージェントごとに判定）
#   - bypass 不可なエージェントは ESCALATION 遷移を促す
set -euo pipefail

STATE=sprint/state.json
[ -f "$STATE" ] || { echo "ERR: state.json not found" >&2; exit 1; }

phase=$(jq -r '.phase' "$STATE")
sub_phase=$(jq -r '.sub_phase // "implement"' "$STATE")
agreed=$(jq -r '.contract.agreed // false' "$STATE")
in_flight=$(jq -r '.resume_hint.in_flight // [] | length' "$STATE")

gate() { jq -r ".gate_approvals.\"$1\" // false" "$STATE"; }

# §7.10 §10 / §3.2 維持責務:
#   フェーズ遷移ごとの additionalContext に persona compact ブロックを混ぜ込み、
#   Orchestrator が次手を実行する直前で語り口を再接地させる。圧縮後の事前知識補完による
#   他ペルソナ混線（語尾ドリフト）を抑える狙い。
#   - compact のみ（rich は SessionStart / persona-ambient で別経路注入）
#   - persona 未設定 / SPRINT_PERSONA=off / persona.muted=true なら sprint_persona_block が
#     無出力になるため、自動的に no-op
#   - サブエージェントには絶対に持ち込まない（本ブロックは Orchestrator 宛の next-action のみ）
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE_FILE="$ROOT/sprint/state.json"
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_persona.sh" 2>/dev/null || true
if command -v sprint_persona_block >/dev/null 2>&1; then
  _persona_compact=$(sprint_persona_block compact 2>/dev/null || true)
  if [ -n "$_persona_compact" ]; then
    printf '%s\n\n' "$_persona_compact"
  fi
fi

# runtime hint 出力（Wave E / T-E.10）:
#   agent 名を引数に、sprint/.agents.merged.json を引いて model_id と effort を取得し、
#   「（注入: model=..., effort=... で動作するよう Task プロンプトに含めてください）」を1行出力する。
#   merged.json が無い・該当 agent エントリが無い場合は何も出さない（フロントマター既定値にフォールバック）。
#   この一行は state.json の書込指示を含まないため、R1 担保（test_phase_advance.sh）に影響しない。
emit_runtime_hint() {
  local agent="$1"
  local merged="sprint/.agents.merged.json"
  [ -f "$merged" ] || return 0
  local mid eff
  mid=$(jq -r --arg a "$agent" '.agents[$a].model_id // empty' "$merged" 2>/dev/null)
  eff=$(jq -r --arg a "$agent" '.agents[$a].effort // empty' "$merged" 2>/dev/null)
  [ -n "$mid" ] && [ -n "$eff" ] && echo "（注入: model=$mid, effort=$eff で動作するよう Task プロンプトに含めてください）"
}

# quarantine 判定: agent 名を引数に、quarantine 中なら 0 を返す
is_quarantined() {
  local agent="$1"
  local until_ms
  until_ms=$(jq -r --arg a "$agent" '.subagent_health[$a].quarantine_until // 0' "$STATE")
  local now_ms
  now_ms=$(($(date +%s%N) / 1000000))
  [ "$until_ms" -gt "$now_ms" ]
}

# bypass 指示出力: agent 名を引数に、bypass 経路の指示を出す（bypass 不可なら ESCALATION）
emit_bypass_or_escalation() {
  local agent="$1"
  case "$agent" in
    investigator)
      echo "investigator quarantine 中。bug-hunter の FINDINGS をそのまま BRIEF として代用してください。clarifier 起動時のパラメータを sprint/IMPROVE_FINDINGS.md に変更します。"
      ;;
    consistency-mgr)
      echo "consistency-mgr quarantine 中。--heal を適用せず、警告のみで継続します。Human にこの旨を AskUserQuestion で通知してください。"
      ;;
    reviewer)
      echo "reviewer quarantine 中。Stage1（仕様準拠）を Worker 自身に自己照合させ、Stage2 は INTEGRATE 後に retry してください。"
      ;;
    escalation-mgr)
      echo "escalation-mgr quarantine 中。未整形の生 failure_log を AskUserQuestion で提示してください。"
      ;;
    *)
      echo "${agent} quarantine 中（bypass 不可）。ESCALATION フェーズへ遷移してください。escalation-mgr 自体が quarantine の場合は生 failure_log を Human に提示してください。"
      ;;
  esac
}

case "$phase" in
  CLARIFY)
    if [ "$sub_phase" = "improve" ]; then
      if [ ! -f sprint/IMPROVE.md ]; then
        if is_quarantined clarifier; then
          emit_bypass_or_escalation clarifier
        else
          echo "clarifier サブエージェントを起動してください。パラメータ: sprint/IMPROVE_BRIEF.md。期待成果物: sprint/IMPROVE.md（修正スコープ宣言）。"
          emit_runtime_hint clarifier
        fi
      elif [ "$(gate IMPROVE_CLARIFY_TO_DESIGN)" != "true" ]; then
        echo "AskUserQuestion で改善 CLARIFY→DESIGN 承認を求めてください（承認時は clarifier に gate_approvals.IMPROVE_CLARIFY_TO_DESIGN=true の書込を依頼してください）。"
      else
        if is_quarantined designer; then
          emit_bypass_or_escalation designer
        else
          echo "designer サブエージェントを起動してください。パラメータ: sprint/IMPROVE_BRIEF.md, sprint/IMPROVE.md。"
          emit_runtime_hint designer
        fi
      fi
    else
      if [ ! -f sprint/PRODUCT.md ]; then
        if is_quarantined clarifier; then
          emit_bypass_or_escalation clarifier
        else
          echo "clarifier サブエージェントを起動してください。期待成果物: sprint/PRODUCT.md。"
          emit_runtime_hint clarifier
        fi
      elif [ "$(gate CLARIFY_TO_DESIGN)" != "true" ]; then
        echo "AskUserQuestion で CLARIFY→DESIGN 承認を求めてください（承認時は clarifier に gate_approvals.CLARIFY_TO_DESIGN=true の書込を依頼してください）。"
      else
        if is_quarantined designer; then
          emit_bypass_or_escalation designer
        else
          echo "designer サブエージェントを起動してください。"
          emit_runtime_hint designer
        fi
      fi
    fi
    ;;
  DESIGN)
    if [ ! -f sprint/SPRINT.md ]; then
      if is_quarantined designer; then
        emit_bypass_or_escalation designer
      else
        echo "designer サブエージェントを起動してください。"
        emit_runtime_hint designer
      fi
    else
      if is_quarantined decomposer; then
        emit_bypass_or_escalation decomposer
      else
        echo "decomposer サブエージェントを起動してください。"
        emit_runtime_hint decomposer
      fi
    fi
    ;;
  PLAN)
    if [ "$agreed" != "true" ]; then
      if is_quarantined decomposer; then
        emit_bypass_or_escalation decomposer
      else
        echo "decomposer サブエージェントを起動して契約合意まで進めてください。"
        emit_runtime_hint decomposer
      fi
    elif ! bash scripts/plan-waves.sh > /dev/null 2>&1; then
      cycle_log=$(bash scripts/plan-waves.sh 2>&1 || true)
      if is_quarantined decomposer; then
        emit_bypass_or_escalation decomposer
      else
        echo "DAG 循環を検出しました。decomposer サブエージェントへ差戻してください。循環ログ: ${cycle_log}"
        emit_runtime_hint decomposer
      fi
    else
      if is_quarantined executor; then
        emit_bypass_or_escalation executor
      else
        echo "executor サブエージェントを起動してください。"
        emit_runtime_hint executor
      fi
    fi
    ;;
  EXECUTE)
    if [ "$in_flight" = "0" ]; then
      if is_quarantined executor; then
        emit_bypass_or_escalation executor
      else
        echo "executor サブエージェントを起動し、次ウェーブを開始してください。"
        emit_runtime_hint executor
      fi
    else
      if is_quarantined executor; then
        emit_bypass_or_escalation executor
      else
        echo "executor サブエージェントを起動し、in_flight タスクを継続してください。"
        emit_runtime_hint executor
      fi
    fi
    ;;
  VERIFY)
    if is_quarantined verifier; then
      emit_bypass_or_escalation verifier
    else
      echo "verifier サブエージェントを起動してください。"
      emit_runtime_hint verifier
    fi
    ;;
  INTEGRATE)
    if is_quarantined integrator; then
      emit_bypass_or_escalation integrator
    else
      echo "integrator サブエージェントを起動してください。"
      emit_runtime_hint integrator
    fi
    ;;
  COMPLETE)
    if [ "$sub_phase" = "implement" ]; then
      if is_quarantined bug-hunter; then
        emit_bypass_or_escalation bug-hunter
      else
        echo "bug-hunter サブエージェントを起動してください（TRIAGE 入口・phase 遷移は apply が実施済み）。"
        emit_runtime_hint bug-hunter
      fi
    elif [ "$sub_phase" = "improve" ]; then
      p1=$(jq -r '.triage_artifacts.p1_count // 0' "$STATE")
      p2=$(jq -r '.triage_artifacts.p2_count // 0' "$STATE")
      iter=$(jq -r '.improve_iteration // 0' "$STATE")
      remaining=$((p1+p2))
      if [ "$remaining" -gt 0 ] && [ "$iter" -ge 3 ]; then
        if is_quarantined escalation-mgr; then
          emit_bypass_or_escalation escalation-mgr
        else
          echo "improve_iteration 上限到達。escalation-mgr を起動してください（phase=ESCALATION は apply が遷移済み）。"
          emit_runtime_hint escalation-mgr
        fi
      elif [ "$remaining" -gt 0 ]; then
        if is_quarantined bug-hunter; then
          emit_bypass_or_escalation bug-hunter
        else
          echo "bug-hunter を起動して残存バグの再 triage を開始してください（sub_phase=triage は apply が遷移済み）。"
          emit_runtime_hint bug-hunter
        fi
      else
        if is_quarantined completer; then
          emit_bypass_or_escalation completer
        else
          echo "completer サブエージェントを起動してください。"
          emit_runtime_hint completer
        fi
      fi
    else
      if is_quarantined completer; then
        emit_bypass_or_escalation completer
      else
        echo "completer サブエージェントを起動してください。"
        emit_runtime_hint completer
      fi
    fi
    ;;
  TRIAGE)
    # TRIAGE 突入経路を bug-hunter に伝達（提案 X）。
    #   complete_implement     : 通常完走経路（実装 COMPLETE 直後）
    #   verify_unresolved      : VERIFY ミニループ上限到達による強制合流
    #   complete_improve_loop  : 改善フェーズ COMPLETE/improve からの再合流
    entry_reason=$(jq -r '.triage_artifacts.entry_reason // "unknown"' "$STATE")
    if [ ! -f sprint/IMPROVE_FINDINGS.md ]; then
      if is_quarantined bug-hunter; then
        emit_bypass_or_escalation bug-hunter
      else
        echo "bug-hunter サブエージェントを起動してください。期待成果物: sprint/IMPROVE_FINDINGS.md。"
        echo "（TRIAGE 突入経路: entry_reason=${entry_reason} — verify_unresolved なら evaluator FAIL 採点の再解釈に重点、complete_improve_loop なら前回 BRIEF との差分に焦点）"
        emit_runtime_hint bug-hunter
      fi
    elif [ ! -f sprint/IMPROVE_BRIEF.md ]; then
      if is_quarantined investigator; then
        emit_bypass_or_escalation investigator
      else
        echo "investigator サブエージェントを起動してください。パラメータ: sprint/IMPROVE_FINDINGS.md。期待成果物: sprint/IMPROVE_BRIEF.md。"
        emit_runtime_hint investigator
      fi
    else
      p1=$(jq -r '.triage_artifacts.p1_count // 0' "$STATE")
      p2=$(jq -r '.triage_artifacts.p2_count // 0' "$STATE")
      if [ "$((p1+p2))" = "0" ]; then
        if is_quarantined completer; then
          emit_bypass_or_escalation completer
        else
          echo "P1/P2 ゼロ。completer を起動してください（apply が sub_phase=implement, phase=COMPLETE に戻し済み）。"
          emit_runtime_hint completer
        fi
      elif [ "$(gate TRIAGE_TO_IMPROVE)" != "true" ]; then
        echo "AskUserQuestion で改善フェーズ GO/中止を確認してください（承認時は investigator に gate_approvals.TRIAGE_TO_IMPROVE=true の書込を依頼してください）。IMPROVE_BRIEF.md のサマリを提示してください。"
      else
        if is_quarantined clarifier; then
          emit_bypass_or_escalation clarifier
        else
          echo "clarifier を起動してください（apply が sub_phase=improve, phase=CLARIFY に遷移済み）。パラメータ: sprint/IMPROVE_BRIEF.md。"
          emit_runtime_hint clarifier
        fi
      fi
    fi
    ;;
  ESCALATION)
    if is_quarantined escalation-mgr; then
      emit_bypass_or_escalation escalation-mgr
    else
      echo "escalation-mgr が生成した3点通知を AskUserQuestion で提示してください。"
      emit_runtime_hint escalation-mgr
    fi
    ;;
  *)
    echo "ERR: unknown phase=$phase" >&2; exit 1 ;;
esac
