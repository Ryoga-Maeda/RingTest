#!/usr/bin/env bash
# .claude/sprint/hooks/session-start.sh
# SessionStart フック — 状態復元・プル型注入（§6.3, §6.4.2, §6.4.7）
# 全文 cat せず、要約 + 読むべきパスのみ注入。MAX_INJECT_BYTES で切り詰め。
#
# 発火ソース（settings.json matcher: startup|resume|compact）:
#   compact（コンテキスト自動/手動圧縮後の再開）を含めるのは、圧縮でペルソナ定義（語尾・口癖）と
#   V2 規律 (L1 フレームワークヘッダ) がコンテキストから消え、モデルが事前知識の典型語尾で補完して
#   語尾が混線するのを防ぐため＝圧縮後に状態サマリ・規律・語り口を再注入する。
#   compact 発火の安全性: 本フックの state 更新（hook_heartbeat 更新）と persona 抽選はいずれも
#   冪等かつ「現在の state」だけで決まり、発火ソースに依存しない。よって compact 発火で
#   二重注入や不正な副作用は生じない。

set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$ROOT/sprint/state.json"
# §11.2 R-1: v1 RULES.md は削除済み。V2 の規律 (R0〜R6 + 9 原則 + state.json 読書ルール) は
# サブエージェント共通の L1 フレームワークヘッダに集約され、ここから注入する。
RULES_FILE="$ROOT/.claude/agents/_prefix/L1-framework-header.md"
MAX_INJECT_BYTES="${SPRINT_MAX_INJECT_BYTES:-2000}"

# 非アクティブなら no-op
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_guard.sh" 2>/dev/null || exit 0

# FR-3: フック生存カナリア。発火ごとに hook_heartbeat を更新する（フック死亡検知の一次マーカー）。
NOW_HB=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
if [ -n "$NOW_HB" ]; then
  jq --arg h "$NOW_HB" '.hook_heartbeat = $h' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
    && mv "$STATE_FILE.tmp" "$STATE_FILE" || rm -f "$STATE_FILE.tmp"
fi

# state.json から必要フィールドだけ取得
SPRINT_ID=$(jq -r '.sprint_id // "sprint-1"' "$STATE_FILE" 2>/dev/null || echo "sprint-1")
PHASE=$(jq -r '.phase // "UNKNOWN"' "$STATE_FILE" 2>/dev/null || echo "UNKNOWN")
RUN_STATE=$(jq -r '.run_state // "OFF"' "$STATE_FILE" 2>/dev/null || echo "OFF")
CURRENT_TASK=$(jq -r '.resume_hint.current_task // "なし"' "$STATE_FILE" 2>/dev/null || echo "なし")
# IH-W2: in-flight 集合（複数タスク同時進行）を優先注入する。current_task は後方互換で残すが、
# 並列ウェーブ途中中断では飛行中タスクが複数ありうるため in_flight を再開の主情報とする。
IN_FLIGHT=$(jq -r '.resume_hint.in_flight[]? // empty' "$STATE_FILE" 2>/dev/null || echo "")
NEXT_ACTION=$(jq -r '.resume_hint.next_action // "state.json を確認して継続してください"' "$STATE_FILE" 2>/dev/null || echo "state.json を確認して継続してください")
CONTRACT_AGREED=$(jq -r '.contract.agreed // false' "$STATE_FILE" 2>/dev/null || echo "false")
# 保全 push 失敗の記録（②再開・レジリエンス用。.resilience 名前空間）。
PERSIST_FAILED=$(jq -r '.resilience.persist_failed // false' "$STATE_FILE" 2>/dev/null || echo "false")
PERSIST_FAILED_BRANCHES=$(jq -r '.resilience.persist_failed_branches[]? // empty' "$STATE_FILE" 2>/dev/null || echo "")

# FR-4 補完（再接地ガード）: 直前に tool-call parse 失敗があった再開かを検出する。
# parse 失敗は宙ぶらりんの tool_use を履歴に残して会話を内部的に不整合にする。その汚染履歴を
# 土台に自動再開（compact 後の再注入 / 新セッション）すると、モデルが「やってもいない作業を
# 完了した」と作話する＝大きなハルシネーションを起こす。検出時は注入の最上段に「実体を検証して
# から続けよ」という再接地指示を置き、これを抑止する。取りこぼし防止に2系統で検出する:
#   (B) 新セッション再起動経路 — 外部監視 (V2 では resilience.sh) が立てた .resilience.parse_failure_recent を読む。
#       新セッションでは tee が SESSION_LOG を truncate して末尾走査が効かないため、この state
#       フラグが主検出となる。一度きりで消費する（下でクリア）。
#   (A) compact / 同一セッション経路 — runner はプロセス内 compact に介在できないため、runner 捕捉
#       ログ SESSION_LOG の末尾に parse 失敗痕跡が残っているかを直接走査して補完する。
PARSE_FAILURE_RECENT=$(jq -r '.resilience.parse_failure_recent // false' "$STATE_FILE" 2>/dev/null || echo "false")
SESSION_LOG="${SPRINT_SESSION_LOG:-$ROOT/sprint/.session-out.log}"
PARSE_POISON_PATTERN="${SPRINT_POISON_PATTERN:-could not be parsed}"
PARSE_SCAN_LINES="${SPRINT_POISON_SCAN_LINES:-80}"
REGROUND=0
if [ "$PARSE_FAILURE_RECENT" = "true" ]; then
  REGROUND=1
elif [ -f "$SESSION_LOG" ] && \
     tail -n "$PARSE_SCAN_LINES" "$SESSION_LOG" 2>/dev/null | grep -q "$PARSE_POISON_PATTERN" 2>/dev/null; then
  REGROUND=1
fi
# 一度きりのフラグ (B) はここで消費（クリア）する。true だったときだけ書き込み、毎回の state 書込を避ける。
# (A) の SESSION_LOG 検出は痕跡が末尾80行から流れ落ちれば自然に止む（クリア不要）。
if [ "$PARSE_FAILURE_RECENT" = "true" ]; then
  jq '.resilience.parse_failure_recent = false' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
    && mv "$STATE_FILE.tmp" "$STATE_FILE" || rm -f "$STATE_FILE.tmp"
fi

# オーケストレーター人格の抽選（冪等・防御的）。通常は cloud-kickoff が抽選済みだが、
# ランナー非介在の再開（再 clone 等）でも未設定なら1つ抽選しておく。失敗は無視。
#
# §10 継承の整理 (PERSONA_INHERITANCE_PLAN.md T3):
#   v2_active=true のときは下流の `persona-init-v2.sh` が同じ `sprint_roll_persona` を
#   呼ぶため、ここで二重抽選するのを避ける。v2 経路では persona-init-v2.sh に一本化し、
#   v1 並走 (v2_active=false) 時のみ本フックで `sprint_roll_persona` を直接呼ぶ。
#   `sprint_persona_block` (compact 注入用) は両経路で必要なので source 自体は常に行う。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_persona.sh" 2>/dev/null || true
if [ "$(jq -r '.v2_active // false' "$STATE_FILE" 2>/dev/null || echo false)" != "true" ]; then
  command -v sprint_roll_persona >/dev/null 2>&1 && sprint_roll_persona || true
fi

# read_first パスを改行区切りで取得
READ_FIRST=$(jq -r '.resume_hint.read_first[]? // empty' "$STATE_FILE" 2>/dev/null || echo "sprint/state.json")

# 状態↔実体 整合性検証（ARCHITECTURE_RETROSPECTIVE 1-1）。
# 再開時に state.json の主張と git 実体の乖離（未 push ブランチの喪失等）を検出して警告する。
# 乖離があるとき（exit 3）のみ注入する。set -e 下なので明示的に rc を捕捉する。
CONSISTENCY_OUT=""; CONSISTENCY_RC=0
if [ -f "$ROOT/scripts/check-consistency.sh" ]; then
  set +e
  CONSISTENCY_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" bash "$ROOT/scripts/check-consistency.sh" 2>/dev/null)
  CONSISTENCY_RC=$?
  set -e
fi

# 注入テキストを構築
build_output() {
  # 再接地ガード（FR-4 補完）: parse 失敗直後の自動再開では、汚染履歴での作話を防ぐため最優先で
  # 「実体検証から再開せよ」を促す。バイトキャップで落とされないよう最上段に置く。
  if [ "$REGROUND" = "1" ]; then
    echo "## ⚠️ パース失敗からの再開（再接地・ファイルから再水和）"
    echo ""
    echo "直前のターンで tool 呼び出しのパースに失敗しています（履歴が汚染されている可能性）。**圧縮後の要約・直前の自分の主張・ツール結果を信頼しないこと。** いかなるタスクも「完了済み」と仮定しないこと。"
    echo ""
    echo "**再水和の手順（この順で実体から状況を作り直す）**:"
    echo "1. \`sprint/checkpoint.md\` を読む（直近の進捗・タスク表・next_action の機械生成スナップショット＝再開の主情報源）。"
    echo "2. \`sprint/state.json\` で phase・契約合意・各タスク status / tdd_phase を確認する。"
    echo "3. \`git status\` と対象ファイルの実体を確認し、checkpoint の主張と一致するか突き合わせる（未コミット WIP・未 push の有無）。"
    echo "4. 上の実体だけを根拠に次の一手を決める。**真実の源は \`sprint/\` 配下のファイルであり、汚染され得る会話コンテキストではない。**"
    echo ""
  fi
  echo "## スプリント状態サマリー"
  echo ""
  echo "- **スプリント**: $SPRINT_ID"
  echo "- **フェーズ**: $PHASE"
  echo "- **状態**: $RUN_STATE"
  echo "- **契約合意**: $CONTRACT_AGREED"
  echo "- **実行中タスク**: $CURRENT_TASK"
  # IH-W2: 飛行中タスク集合（複数同時進行）を列挙。各タスクの「次の一手」は checkpoint.md 参照。
  if [ -n "$IN_FLIGHT" ]; then
    IN_FLIGHT_CSV=$(printf '%s' "$IN_FLIGHT" | tr '\n' ',' | sed 's/,$//')
    echo "- **飛行中タスク（in_flight）**: $IN_FLIGHT_CSV"
  fi
  echo ""
  echo "## 次のアクション"
  echo ""
  echo "$NEXT_ACTION"
  echo ""

  # 整合性の乖離があれば最優先で注入（バイトキャップで切り詰められないよう上部に置く）。
  if [ "$CONSISTENCY_RC" = "3" ] && [ -n "$CONSISTENCY_OUT" ]; then
    echo "$CONSISTENCY_OUT"
    echo ""
  fi

  # 保全 push 失敗の警告（IH-W5/W8）。未 push ブランチの喪失リスクを最優先で明示する。
  if [ "$PERSIST_FAILED" = "true" ]; then
    echo "## ⚠️ 保全 push 失敗（喪失リスク）"
    echo ""
    echo "前回の中断で次のブランチの push に失敗しています。コンテナ破棄で成果が失われた恐れがあります:"
    while IFS= read -r br; do
      [ -n "$br" ] && echo "- \`$br\`（再 push を推奨。check-consistency で喪失有無を確認）"
    done <<< "$PERSIST_FAILED_BRANCHES"
    echo ""
  fi

  echo "## 優先して読むファイル"
  echo ""
  while IFS= read -r path; do
    [ -n "$path" ] && echo "- \`$path\`"
  done <<< "$READ_FIRST"
  echo ""

  # オーケストレーター人格（ユーザー対話のトーンのみ）。無効/未設定なら無出力。
  # 規律 (L1 フレームワークヘッダ) より前に置き、バイトキャップで先に落とされないようにする。
  # スプリント中の再開注入は規律とバイト予算を取り合うため compact（style のみ）に抑える。
  # 一人称/語尾/口癖/セリフ例まで含む rich は起動(cloud-kickoff)・通常開発(persona-ambient)で出す。
  if command -v sprint_persona_block >/dev/null 2>&1; then
    _persona_block=$(sprint_persona_block compact 2>/dev/null || true)
    if [ -n "$_persona_block" ]; then
      echo "$_persona_block"
      echo ""
    fi
  fi

  # V2 規律の注入（スプリント時のみ — 通常 CLAUDE.md を汚さない）
  # §11.2 R-1: v1 RULES.md → V2 L1 フレームワークヘッダに切替
  if [ -f "$RULES_FILE" ]; then
    echo "---"
    echo ""
    echo "## スプリント規則 (V2 L1 フレームワークヘッダ)"
    echo ""
    cat "$RULES_FILE"
    echo ""
  fi
}

# UTF-8 安全なバイトトランケーション（python3 不在／失敗時のフォールバック）。
# 末尾でマルチバイト文字を割って不正 UTF-8 を additionalContext に注入しないようにする。
_sprint_fallback_trim() {
  if command -v iconv >/dev/null 2>&1; then
    # バイトキャップで切ってから、末尾の不完全/不正バイト列を iconv -c で破棄する。
    head -c "$MAX_INJECT_BYTES" 2>/dev/null | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
    return 0
  fi
  # iconv も無い場合: キャップ内の最後の改行までで切る（改行は文字境界なので常に妥当な UTF-8）。
  # 改行が無ければやむを得ず素朴に切る（最終フォールバック）。
  local buf
  buf=$(head -c "$MAX_INJECT_BYTES" 2>/dev/null || true)
  if [ "${buf%$'\n'*}" != "$buf" ]; then
    printf '%s\n' "${buf%$'\n'*}"
  else
    printf '%s' "$buf"
  fi
}

# バイト数キャップを適用して出力（UTF-8 文字境界を考慮）
# 一旦バッファに溜めてから切断することで SIGPIPE を回避する
_SPRINT_BUF=$(build_output) || true
if command -v python3 >/dev/null 2>&1; then
  # python3 で UTF-8 継続バイト(0x80-0xBF)を除去しながらトランケート。
  # 継続バイトを剥がした後に末尾が不完全な先頭バイト(>=0xC0)になった場合はそれも落とす
  # （完全なマルチバイト文字は必ず継続バイトで終わるため、末尾が先頭バイト＝不完全と確定できる）。
  # Python コードは ASCII のみ（シェル文字列のエンコード問題を回避）
  printf '%s' "$_SPRINT_BUF" | python3 -c "
import sys
n=${MAX_INJECT_BYTES}
d=sys.stdin.buffer.read(n)
while d and (d[-1]&0xC0)==0x80:
    d=d[:-1]
if d and d[-1]>=0xC0:
    d=d[:-1]
sys.stdout.buffer.write(d)
" 2>/dev/null || printf '%s' "$_SPRINT_BUF" | _sprint_fallback_trim
else
  printf '%s' "$_SPRINT_BUF" | _sprint_fallback_trim
fi
unset _SPRINT_BUF

# V2 phase-advance injection
# v2_active = true のときのみ、schema 拡張 → persona 抽選 → phase 遷移適用 + 次手注入を行う。
# いずれのスクリプトも冪等で、v1 only の state.json には作用しない設計（各スクリプト内で v2_active 判定）。
# 失敗しても v1 既存フローを壊さないよう、各段の戻り値は無視する（best-effort）。
if [ -f sprint/state.json ] && [ "$(jq -r '.v2_active // false' sprint/state.json 2>/dev/null)" = "true" ]; then
  # 1) schema 拡張を冪等に適用（v1 既存 state.json も対応）
  bash scripts/migrate-state-v2.sh >/dev/null 2>&1 || true
  # 2) persona 抽選（未初期化時のみ）
  bash scripts/persona-init-v2.sh >/dev/null 2>&1 || true
  # 3) agents.config の merge + validate（Wave E）
  #    - merge: agents.config.json + agents.local.json + model-catalog.json → sprint/.agents.merged.json
  #    - validate: enum / max effort 許可 / model_version 存在性検査
  #    - validate 失敗時は merged.json を破棄し、各 agent のフロントマター既定値にフォールバックさせる
  #    - phase-advance より前に走らせる理由: phase-advance が agent 起動指示を出す際に merged 設定を引くため
  if [ -f scripts/agents-config-merge.sh ]; then
    bash scripts/agents-config-merge.sh >/dev/null 2>&1 || true
    if [ -f scripts/validate-agents-config.sh ] && ! bash scripts/validate-agents-config.sh 2>/dev/null; then
      echo "agents config validation failed. Falling back to frontmatter defaults." >&2
      rm -f sprint/.agents.merged.json
    fi
  fi
  # 4) phase 遷移適用 + 次手注入（stdout は phase-advance.sh が hookSpecificOutput JSON で出す）
  bash .claude/sprint/hooks/phase-advance.sh || true
fi
