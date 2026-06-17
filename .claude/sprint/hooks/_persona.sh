#!/usr/bin/env bash
# .claude/sprint/hooks/_persona.sh
# オーケストレーター人格（ランダム・パーソナリティ）の抽選と注入ブロック生成。
#
# 目的:
#   Orchestrator がユーザーと会話・報告する際の「語り口（トーン）」をスプリント単位で
#   ランダムに1つ選び、state.json.persona に永続化する。再開（再 clone）を跨いでも同じ
#   人格を維持し（IP-4 prefix 凍結＝セッション内でトーンを固定）、スプリントが切り替わると
#   スプリントロールオーバー (V2 では PhaseAdvance フック経由) の state 再構築で persona が
#   落ちて自然に再抽選される。
#
#   人格は「ユーザー向けの語り口」だけに適用し、判断・状態機械の論理・サブエージェントへの
#   指示・RULES 遵守・技術的内容の正確さ・エスカレーション/承認依頼の明確さには一切影響させない。
#
#   抽選された人格は state.json.persona に残り続け、スプリント終了後・次スプリント開始前の
#   「通常開発中」も persona-ambient.sh（ルート SessionStart）が同じ語り口を継続注入する。
#   次スプリントのロールオーバー (V2 では PhaseAdvance フック経由) で persona が落ちて再抽選される。
#
# 無効化:
#   SPRINT_PERSONA を off / 0 / false / no（大小無視）にすると抽選・注入を行わない。
#
# 依存変数: ROOT・STATE_FILE（呼び出し元が設定済みであること）。
# 公開関数:
#   sprint_persona_enabled        # 有効なら 0、無効（env で OFF）なら 1
#   sprint_roll_persona           # 冪等。persona 未設定かつ有効時のみ1つ抽選して永続化（カタログの全フィールドを保存）。
#                                 # 新規抽選時は制御ブランチへ最善努力で checkpoint する（_control_commit.sh 再利用。
#                                 # 再 clone を跨ぐ維持を仕組みで保証し、コミット要否の Human 確認を不要にする）
#   sprint_persona_block [mode]   # 現在の persona の注入用 markdown を stdout に出す（無効/未設定なら無出力）
#                                 # mode=compact（既定）: style のみ＝バイト予算を守る（スプリント中の再開注入向け）
#                                 # mode=rich          : 一人称/呼び方/語尾/口癖/セリフ例まで描画（起動・通常開発向け）

# 二重 source ガード。
if [ -z "${__SPRINT_PERSONA_SH_LOADED:-}" ]; then
__SPRINT_PERSONA_SH_LOADED=1

# 原子的 state 更新（update_state）を取り込む。既に読み込まれていれば再定義しない。
if ! command -v update_state >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  source "$(dirname "${BASH_SOURCE[0]}")/_state.sh" 2>/dev/null || true
fi

# 人格カタログのパス。
__sprint_persona_catalog() { printf '%s\n' "${ROOT:?ROOT 未設定}/.claude/sprint/personas.json"; }

# env による無効化判定。
sprint_persona_enabled() {
  case "$(printf '%s' "${SPRINT_PERSONA:-}" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no|disable|disabled) return 1 ;;
    *) return 0 ;;
  esac
}

# 冪等抽選。persona 未設定（id 空）かつ有効、カタログが妥当なときだけ1つ選んで state へ書く。
sprint_roll_persona() {
  sprint_persona_enabled || return 0
  [ -n "${STATE_FILE:-}" ] && [ -f "$STATE_FILE" ] || return 0
  command -v update_state >/dev/null 2>&1 || return 0

  local catalog cur n idx persona
  catalog="$(__sprint_persona_catalog)" || return 0
  [ -f "$catalog" ] || return 0

  # 既に設定済みなら何もしない（再開を跨いで同一人格を維持）。
  cur=$(jq -r '.persona.id // empty' "$STATE_FILE" 2>/dev/null || echo "")
  [ -n "$cur" ] && return 0

  n=$(jq '.personas | length' "$catalog" 2>/dev/null || echo 0)
  case "$n" in (''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] || return 0

  # bash の $RANDOM で 0..n-1 を抽選（小さな n では剰余バイアスは無視できる）。
  idx=$(( RANDOM % n ))
  # カタログの persona オブジェクトを丸ごと保存する（id/name/style に加え、表現を豊かにする任意
  # フィールド first_person/address/speech/examples も state に凍結＝再開を跨いで同一の語り口を維持）。
  persona=$(jq -c --argjson i "$idx" '.personas[$i]' "$catalog" 2>/dev/null || echo "")
  [ -n "$persona" ] && [ "$persona" != "null" ] || return 0

  update_state '.persona = $p' --argjson p "$persona" 2>/dev/null || return 0

  # 抽選直後の制御面永続化（IH-W6 の前倒し）。抽選結果は作業ツリーの state.json に書かれる
  # だけで、通常終了（中断シグナルなし）では on-stop の制御面コミットが走らず、ephemeral
  # コンテナの回収で人格が消える＝「再 clone を跨いで維持」の謳いと乖離していた。新規抽選時に
  # 限り制御ブランチ（sprint/<sprint_id>）へ最善努力で commit/push し、「未コミットの人格」
  # 状態を短命にする（エージェントがコミット要否を Human へ確認する誘因も断つ）。
  # HEAD・作業ブランチは触らない（plumbing コミット）。失敗してもセッションを壊さない。
  # 非 git 環境では no-op、remote 未設定では push のみ省略される。
  if ! command -v sprint_control_plane_commit >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "$(dirname "${BASH_SOURCE[0]}")/_control_commit.sh" 2>/dev/null || true
  fi
  command -v sprint_control_plane_commit >/dev/null 2>&1 && sprint_control_plane_commit || true
  return 0
}

# 注入ブロックを stdout に出力する。無効（env OFF）・persona 未設定なら何も出さない。
# 第1引数 mode（compact|rich）で詳細度を切替える。compact=style のみ（バイト予算を守る）、
# rich=構造化フィールド（一人称/呼び方/語尾/口癖/セリフ例）まで描画。任意フィールドは欠落時に
# 行ごと省略するため、旧スキーマ（id/name/style だけの persona）でも安全に動作する。
sprint_persona_block() {
  sprint_persona_enabled || return 0
  [ -n "${STATE_FILE:-}" ] && [ -f "$STATE_FILE" ] || return 0

  local mode="${1:-compact}"
  local id name style
  id=$(jq -r '.persona.id // empty' "$STATE_FILE" 2>/dev/null || echo "")
  [ -n "$id" ] || return 0
  # persona.muted=true なら無出力（会話からのスプリント単位停止。SPRINT_PERSONA=off は環境単位）。
  local muted
  muted=$(jq -r '.persona.muted // false' "$STATE_FILE" 2>/dev/null || echo "false")
  [ "$muted" = "true" ] && return 0
  name=$(jq -r '.persona.name // ""' "$STATE_FILE" 2>/dev/null || echo "")
  style=$(jq -r '.persona.style // ""' "$STATE_FILE" 2>/dev/null || echo "")

  echo "## オーケストレーター人格（ユーザー対話のトーンのみ）"
  echo ""
  echo "- **人格**: $name"
  echo "- **話し方**: $style"

  # compact でも一人称・呼び方を出す（ドリフト防止）。欠落時は行ごと省略（旧スキーマ互換）。
  local fp addr
  fp=$(jq -r '.persona.first_person // empty' "$STATE_FILE" 2>/dev/null || echo "")
  addr=$(jq -r '.persona.address // empty' "$STATE_FILE" 2>/dev/null || echo "")
  [ -n "$fp" ]   && echo "- **一人称**: $fp"
  [ -n "$addr" ] && echo "- **呼び方**: $addr"

  # 語尾リスト（speech.endings）は両モードで出す。compact でも出すのは、コンテキスト圧縮後の
  # 再注入で「正しい語尾」を明示してドリフト（他ペルソナの典型語尾での補完＝混線）を抑えるため。
  # 欠落時は行ごと省略（旧スキーマ／speech 無しの persona でも安全）。
  local endings
  endings=$(jq -r '(.persona.speech.endings // []) | join(" / ")' "$STATE_FILE" 2>/dev/null || echo "")
  [ -n "$endings" ] && echo "- **語尾**: $endings"

  # rich のときだけ残りの構造化フィールドを描画する。コア定義(style)・語尾は両モード共通。
  # セリフ例(examples)はモデルが語り口を学ぶ最有効打。各行は欠落フィールドを省いて防御的に出す。
  if [ "$mode" = "rich" ]; then
    local tics examples
    tics=$(jq -r '(.persona.speech.tics // []) | join(" / ")' "$STATE_FILE" 2>/dev/null || echo "")
    [ -n "$tics" ]    && echo "- **口癖**: $tics"
    examples=$(jq -r '.persona.examples[]? | select((.line // "") != "") | "    - （\(.on // "例")）\(.line)"' "$STATE_FILE" 2>/dev/null || echo "")
    if [ -n "$examples" ]; then
      echo "- **セリフ例（語り口の見本。数値・要点・依頼は明確に）**:"
      printf '%s\n' "$examples"
    fi

    # 語り口の運用ルール（rich のみ。カタログ欠落・旧スキーマでも常に効く堅牢性を優先してここにハードコード）。
    echo "- **語り口の運用ルール（必須）**:"
    echo "    1. 口癖は文脈に合うときだけ使う。1返信に最大1回。連続するターンで同じ口癖を繰り返さない。"
    echo "    2. 掛け声系の口癖（「せーのっ」等）を報告・回答の冒頭挨拶にしない（実際に行動を開始する瞬間だけ使う）。"
    echo "    3. 締めの口癖を毎返信の末尾に付けない。事実や依頼で文を終えてよい。"
    echo "    4. 情報量ゼロの定型締めを付けない。「何かあったら言ってね」だけでなく、次回予告（「終わったらまた報告するね」）・見守り保証（「安心して待ってて」）も毎返信に付けない。"
    echo "    5. セリフ例は語り口の見本であり、文面を丸写ししない。状況に合わせて自分の言葉で言い換える。"
    echo "    6. 他のペルソナの口癖・語尾を使わない。"
    echo "    7. 返信の長さは情報量に比例させる（短い質問には短く答える）。"
  fi

  # 不変条件注記: compact は1行に収める（バイト予算保護。tests/test_persona.sh が全 persona 900B 以内を契約。
  # 圧縮後の混線防止で「他のペルソナの口癖・語尾を使わない」を含める）、rich は全文を出す（安全マージン強化）。
  if [ "$mode" = "rich" ]; then
    echo "> この人格は **ユーザーへの会話・報告の語り口** だけに適用する。次には**一切影響させない**: 判断・状態機械・サブエージェント指示・RULES・技術的正確さ・エスカレーション/承認依頼の明確さ、**成果物（コミットメッセージ/PR/コード/ドキュメント）**。深刻な事案（成果喪失・セキュリティ・高コスト判断）では明るい口癖・絵文字を抑える。装飾で本文を水増ししない。セリフ例の文面を丸写ししない。人格を理由に Human への確認・質問を増やさない（確認の要否・方法は人格と無関係に判断する）。"
  else
    echo "> 語り口のみ適用。成果物・判断・RULES・重要連絡には影響させない。深刻な事案では装飾を抑える。上記の語尾だけを使い、他のペルソナの口癖・語尾は使わない。口癖は1返信1回まで。定型締めを付けない。"
  fi
}

fi  # __SPRINT_PERSONA_SH_LOADED
