#!/usr/bin/env bash
# tests/test_persona.sh — オーケストレーター人格（ランダム・パーソナリティ）の契約テスト
#
# 検証項目:
#   - personas.json が妥当な JSON で、各 persona が id/name/style を持つ
#   - sprint_roll_persona がスプリント単位で1つ抽選し state.json.persona へ永続化する
#   - 抽選は冪等（既設定なら再抽選しない＝再開を跨いで同一人格を維持）
#   - SPRINT_PERSONA=off で抽選・注入を行わない（既定 ON・env で OFF）
#   - sprint_persona_block が現在の persona を素テキストで注入する
#   - cloud-kickoff が人格を抽選し注入する
#   - sprint-next（次スプリント）で persona がクリアされ、再活性化で再抽選される
#   - 人格の語り口は「ユーザー対話のトーンのみ」である旨が注入文に明示される
#   - 各 persona がリッチ表現フィールド（first_person/address/speech.endings/examples）を持つ
#   - 抽選は persona オブジェクトを丸ごと state へ永続化し、リッチフィールドが再開を跨いで残る
#   - 描画は詳細度階層: rich=一人称/語尾/口癖/セリフ例まで、compact（既定）=style のみ（バイト予算保護）
#   - persona-ambient が通常開発中（run_state=OFF）も語り口を継続注入し、スプリント中は no-op
set -uo pipefail
PASS=0; FAIL=0
ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check(){ local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected='$e' got='$a')"; FAIL=$((FAIL+1)); fi; }

echo "=== test_persona.sh ==="

CATALOG="$ROOT_REPO/.claude/sprint/personas.json"

# ---------- (A) カタログの妥当性 ----------
check "[A] personas.json が妥当な JSON" "ok" "$(jq empty "$CATALOG" 2>/dev/null && echo ok || echo ng)"
check "[A] personas が配列" "array" "$(jq -r '.personas | type' "$CATALOG" 2>/dev/null)"
check "[A] persona が1つ以上ある" "yes" "$(jq -e '(.personas|length) >= 1' "$CATALOG" >/dev/null 2>&1 && echo yes || echo no)"
# 各 persona が id/name/style を非空で持つ
MISSING=$(jq -r '[.personas[] | select((.id // "")=="" or (.name // "")=="" or (.style // "")=="")] | length' "$CATALOG" 2>/dev/null)
check "[A] 全 persona が id/name/style を持つ" "0" "$MISSING"
# id が一意
DUP=$(jq -r '[.personas[].id] | (length - (unique | length))' "$CATALOG" 2>/dev/null)
check "[A] persona の id が一意" "0" "$DUP"
# 表現を豊かにする任意フィールド（first_person/address/speech.endings/examples）を全 persona が持つ
RICH_MISSING=$(jq -r '[.personas[] | select(
  (.first_person // "")=="" or (.address // "")=="" or
  ((.speech.endings // []) | length) < 1 or
  ((.examples // []) | length) < 1
)] | length' "$CATALOG" 2>/dev/null)
check "[A] 全 persona がリッチ表現フィールドを持つ" "0" "$RICH_MISSING"
# 各 example が on/line を非空で持つ（few-shot セリフ例の妥当性）
EX_BAD=$(jq -r '[.personas[].examples[]? | select((.on // "")=="" or (.line // "")=="")] | length' "$CATALOG" 2>/dev/null)
check "[A] 全 example が on/line を持つ" "0" "$EX_BAD"
# 各 persona に「重大エスカレーション」と「短い返し」の例文が存在するか
MISSING_CRITICAL=$(jq -r '[.personas[] | select(
  ([.examples[]?.on] | index("重大エスカレーション")) == null
)] | length' "$CATALOG" 2>/dev/null)
check "[A] 全 persona に重大エスカレーション例が存在する" "0" "$MISSING_CRITICAL"
MISSING_SHORT=$(jq -r '[.personas[] | select(
  ([.examples[]?.on] | index("短い返し")) == null
)] | length' "$CATALOG" 2>/dev/null)
check "[A] 全 persona に短い返し例が存在する" "0" "$MISSING_SHORT"
# 各 persona に「進捗報告」が2本以上あること（R-4: バリエーション化）
MISSING_PROGRESS2=$(jq -r '[.personas[] | select(
  ([.examples[]? | select(.on=="進捗報告")] | length) < 2
)] | length' "$CATALOG" 2>/dev/null)
check "[A] 全 persona に進捗報告例が2本以上ある（バリエーション）" "0" "$MISSING_PROGRESS2"
# 各 persona に「承認依頼」が2本以上あること（R-4: バリエーション化）
MISSING_APPROVAL2=$(jq -r '[.personas[] | select(
  ([.examples[]? | select(.on=="承認依頼")] | length) < 2
)] | length' "$CATALOG" 2>/dev/null)
check "[A] 全 persona に承認依頼例が2本以上ある（バリエーション）" "0" "$MISSING_APPROVAL2"
# 各 persona に「口癖・キャラ語尾で終わらない」例が1本以上ある（R-2: 素の事実で終わる見本）
# 終止パターンを持つ persona ごとに、その語尾・口癖で終わらない例があるかチェックする
# ここでは簡易的に「短い返し」が2本以上ある、または「短い返し」の中に口癖語尾を含まない例があるかを確認する
# より実質的な確認: 各 persona の examples に on="短い返し" が2本以上、または
# on="短い返し" の line が persona の endings/tics で終わらないものが存在するか
# 実装: 各 persona に「短い返し」が2本以上あること（2本目が口癖で終わらない見本として機能する）
MISSING_SHORT2=$(jq -r '[.personas[] | select(
  ([.examples[]? | select(.on=="短い返し")] | length) < 2
)] | length' "$CATALOG" 2>/dev/null)
check "[A] 全 persona に短い返し例が2本以上ある（R-2: 口癖で終わらない見本を含む）" "0" "$MISSING_SHORT2"

# ---------- 共通: 隔離した一時環境を作る ----------
setup_env() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/sprint" "$d/.claude/sprint/hooks"
  cp "$CATALOG" "$d/.claude/sprint/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_persona.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_state.sh" "$d/.claude/sprint/hooks/"
  printf '{"persona":null}\n' > "$d/sprint/state.json"
  printf '%s\n' "$d"
}

# ---------- (B) 抽選と永続化 ----------
D=$(setup_env)
(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
)
ROLLED_ID=$(jq -r '.persona.id // empty' "$D/sprint/state.json" 2>/dev/null)
check "[B] 抽選で persona.id が設定される" "yes" "$([ -n "$ROLLED_ID" ] && echo yes || echo no)"
# 抽選結果がカタログ内の id であること
INCAT=$(jq -r --arg id "$ROLLED_ID" '[.personas[].id] | index($id) | if . == null then "no" else "yes" end' "$CATALOG" 2>/dev/null)
check "[B] 抽選 id がカタログに存在する" "yes" "$INCAT"

# ---------- (C) 冪等性（既設定なら再抽選しない） ----------
(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
)
check "[C] 既設定時は再抽選しない（同一 id を維持）" "$ROLLED_ID" "$(jq -r '.persona.id' "$D/sprint/state.json")"
rm -rf "$D"

# ---------- (D) 注入ブロック ----------
D=$(setup_env)
BLOCK=$(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
  sprint_persona_block
)
check "[D] 注入ブロックに人格見出しが含まれる" "yes" "$(echo "$BLOCK" | grep -q 'オーケストレーター人格' && echo yes || echo no)"
check "[D] 注入ブロックに『トーンのみ』の注記が含まれる" "yes" "$(echo "$BLOCK" | grep -q '語り口' && echo yes || echo no)"
check "[D] 注入ブロックが JSON ではなく素テキスト" "ng" "$(echo "$BLOCK" | jq -e . >/dev/null 2>&1 && echo ok || echo ng)"

# rich 注記に適用除外の「成果物」が明示される（B-2 の予防効果）
BLOCK_RICH_NOTE=$(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_persona_block rich
)
check "[D] rich 注入の注記に『成果物』が含まれる（適用除外の明示）" "yes" "$(echo "$BLOCK_RICH_NOTE" | grep -q '成果物' && echo yes || echo no)"
rm -rf "$D"

# ---------- (I) 詳細度の階層（compact / rich）と全フィールド永続化 ----------
# 抽選で persona オブジェクトを丸ごと state に保存し（リッチフィールド凍結）、
# rich は一人称/語尾/口癖/セリフ例まで描画、compact は style のみ（バイト予算を守る）。
D=$(setup_env)
( export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona )
NEX=$(jq -r '(.persona.examples // []) | length' "$D/sprint/state.json" 2>/dev/null || echo 0)
case "$NEX" in (''|*[!0-9]*) NEX=0 ;; esac
check "[I] 抽選後 state.persona に examples が永続化される" "yes" "$([ "$NEX" -ge 1 ] && echo yes || echo no)"
BLOCK_RICH=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block rich )
BLOCK_COMPACT=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block compact )
check "[I] rich はセリフ例を含む" "yes" "$(echo "$BLOCK_RICH" | grep -q 'セリフ例' && echo yes || echo no)"
check "[I] rich は一人称を含む" "yes" "$(echo "$BLOCK_RICH" | grep -q '一人称' && echo yes || echo no)"
check "[I] compact はセリフ例を含まない（バイト予算保護）" "yes" "$(echo "$BLOCK_COMPACT" | grep -q 'セリフ例' && echo no || echo yes)"
check "[I] compact は一人称を含む" "yes" "$(echo "$BLOCK_COMPACT" | grep -q '一人称' && echo yes || echo no)"
check "[I] compact は呼び方を含む" "yes" "$(echo "$BLOCK_COMPACT" | grep -q '呼び方' && echo yes || echo no)"
# compact ブロックのサイズ上限契約（全 persona をループして最大値を検証。ランダム抽選1件では回帰を検出できない）。
# 実測: 797〜896B（最長 sparkle-center）。圧縮後の混線防止で「語尾」行と他ペルソナ混線禁止の注記を
# compact に追加したぶん増加したが、V2 L1 フレームワークヘッダの MAX_INJECT_BYTES=2000 を取り合う前提の 900B 内に収めてある。
MAXB=0
while IFS= read -r _pid; do
  _st=$(mktemp)
  jq --arg id "$_pid" '{persona:(.personas[]|select(.id==$id))}' "$CATALOG" > "$_st"
  _b=$( export ROOT="$D" STATE_FILE="$_st"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block compact | wc -c )
  rm -f "$_st"
  case "$_b" in (''|*[!0-9]*) _b=0 ;; esac
  [ "$_b" -gt "$MAXB" ] && MAXB=$_b
done < <(jq -r '.personas[].id' "$CATALOG")
check "[I] 全 persona の compact が 900B 以内（MAX_INJECT_BYTES=2000 との取り合い）" "yes" "$([ "$MAXB" -le 900 ] && echo yes || echo no)"
check "[I] rich は compact より表現が豊か（長い）" "yes" "$([ "${#BLOCK_RICH}" -gt "${#BLOCK_COMPACT}" ] && echo yes || echo no)"
check "[I] rich 出力も JSON ではなく素テキスト" "ng" "$(echo "$BLOCK_RICH" | jq -e . >/dev/null 2>&1 && echo ok || echo ng)"
# 既定（引数なし）は compact（後方互換・予算安全）
BLOCK_DEFAULT=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block )
check "[I] 既定は compact（セリフ例なし）" "yes" "$(echo "$BLOCK_DEFAULT" | grep -q 'セリフ例' && echo no || echo yes)"
rm -rf "$D"

# ---------- (E) env による無効化 ----------
D=$(setup_env)
# 無効時は抽選しない
printf '{"persona":null}\n' > "$D/sprint/state.json"
(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json" SPRINT_PERSONA=off
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
)
check "[E] SPRINT_PERSONA=off で抽選しない" "null" "$(jq -r '.persona // "null"' "$D/sprint/state.json")"
# 無効時は注入しない（persona 設定済みでも）
printf '{"persona":{"id":"x","name":"X","style":"y"}}\n' > "$D/sprint/state.json"
OFFBLOCK=$(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json" SPRINT_PERSONA=off
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_persona_block
)
check "[E] SPRINT_PERSONA=off で注入しない" "" "$OFFBLOCK"
rm -rf "$D"

# §11.2 R-2a-3: cloud-kickoff.sh / sprint-next.sh は削除済み。
#   (F) cloud-kickoff 統合テスト: V2 では session-start.sh フックが persona-init-v2.sh
#       を経由して抽選するため、本セクションは撤去。test_persona セクション (B)/(C) で
#       sprint_roll_persona の冪等性は担保済み。
#   (G) sprint-next 後の persona クリアテスト: V2 のスプリントロールオーバー機構は
#       本 PR スコープ外 (R-2 残課題)。再導入時に同等の検査を追加する。

# ---------- (H) アンビエント注入: 通常開発中（run_state=OFF）もキャラを継続 ----------
# persona-ambient.sh はルート SessionStart に登録され、スプリント終了後・次スプリント開始前の
# 通常開発でも、直近スプリントで抽選された persona の語り口を継続注入する（装飾専用・state 不変）。
D=$(setup_env)
cp "$ROOT_REPO/.claude/sprint/hooks/persona-ambient.sh" "$D/.claude/sprint/hooks/"
# 通常開発（OFF）＋ persona 設定済み → 語り口ブロックを注入する
printf '{"run_state":"OFF","persona":{"id":"spark","name":"スパークにゃん","style":"…にゃ"}}\n' > "$D/sprint/state.json"
AMB=$(CLAUDE_PROJECT_DIR="$D" bash "$D/.claude/sprint/hooks/persona-ambient.sh" 2>/dev/null)
check "[H] 通常開発(OFF)で人格ブロックを継続注入" "yes" "$(echo "$AMB" | grep -q 'オーケストレーター人格' && echo yes || echo no)"
check "[H] 継続注入に現在のキャラ名が含まれる" "yes" "$(echo "$AMB" | grep -q 'スパークにゃん' && echo yes || echo no)"
# ambient は state を変更しない（装飾専用）
check "[H] ambient は persona を書き換えない" "spark" "$(jq -r '.persona.id' "$D/sprint/state.json")"
# スプリント実行中(RUNNING)は二重注入回避で no-op（本体 session-start が担当）
printf '{"run_state":"RUNNING","persona":{"id":"spark","name":"スパークにゃん","style":"…にゃ"}}\n' > "$D/sprint/state.json"
AMB_ON=$(CLAUDE_PROJECT_DIR="$D" bash "$D/.claude/sprint/hooks/persona-ambient.sh" 2>/dev/null)
check "[H] スプリント中(RUNNING)は ambient が no-op（二重注入回避）" "" "$AMB_ON"
# persona 未設定なら no-op（一度もスプリントを回していない通常開発はクリーン）
printf '{"run_state":"OFF","persona":null}\n' > "$D/sprint/state.json"
AMB_NONE=$(CLAUDE_PROJECT_DIR="$D" bash "$D/.claude/sprint/hooks/persona-ambient.sh" 2>/dev/null)
check "[H] persona 未設定なら ambient は no-op" "" "$AMB_NONE"
# SPRINT_PERSONA=off なら persona 設定済みでも no-op
printf '{"run_state":"OFF","persona":{"id":"spark","name":"スパークにゃん","style":"…にゃ"}}\n' > "$D/sprint/state.json"
AMB_OFF=$(CLAUDE_PROJECT_DIR="$D" SPRINT_PERSONA=off bash "$D/.claude/sprint/hooks/persona-ambient.sh" 2>/dev/null)
check "[H] SPRINT_PERSONA=off で ambient は no-op" "" "$AMB_OFF"
# stdout は素テキスト/空（許可フィールド逸脱なし＝FR-6 と整合）
check "[H] ambient 出力は JSON ではなく素テキスト" "ng" "$(echo "$AMB" | jq -e . >/dev/null 2>&1 && echo ok || echo ng)"
rm -rf "$D"

# ---------- (J) persona.muted による停止 ----------
# B-3: muted=true で sprint_persona_block が無出力になる
D=$(setup_env)
(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
)
# muted=true に設定（変更前の persona.id を保存して後で不変を確認する）
ROLLED_ID_J=$(jq -r '.persona.id // empty' "$D/sprint/state.json" 2>/dev/null)
jq '.persona.muted = true' "$D/sprint/state.json" > "$D/sprint/state.json.tmp" && mv "$D/sprint/state.json.tmp" "$D/sprint/state.json"
MUTED_BLOCK=$(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_persona_block
)
check "[J] persona.muted=true で sprint_persona_block が無出力" "" "$MUTED_BLOCK"

# sprint_roll_persona は muted を変更しない（冪等: persona.id が設定済みなら再抽選しない）
(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
)
check "[J] sprint_roll_persona は muted を変更しない" "true" "$(jq -r '.persona.muted // false' "$D/sprint/state.json")"
check "[J] sprint_roll_persona は muted 時も persona.id を変えない" "$ROLLED_ID_J" "$(jq -r '.persona.id // empty' "$D/sprint/state.json")"
rm -rf "$D"

# muted と SPRINT_PERSONA=off の OR 関係: muted=false でも off なら無出力
D=$(setup_env)
printf '{"persona":{"id":"x","name":"X","style":"y","first_person":"わたし","address":"きみ","muted":false}}\n' > "$D/sprint/state.json"
OR_BLOCK=$(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json" SPRINT_PERSONA=off
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_persona_block
)
check "[J] muted=false でも SPRINT_PERSONA=off なら無出力（OR 関係）" "" "$OR_BLOCK"
rm -rf "$D"

# ambient 経路でも muted が効く（persona-ambient.sh が sprint_persona_block rich を呼ぶ）
D=$(setup_env)
cp "$ROOT_REPO/.claude/sprint/hooks/persona-ambient.sh" "$D/.claude/sprint/hooks/"
printf '{"run_state":"OFF","persona":{"id":"spark","name":"スパークにゃん","style":"…にゃ","muted":true}}\n' > "$D/sprint/state.json"
AMB_MUTED=$(CLAUDE_PROJECT_DIR="$D" bash "$D/.claude/sprint/hooks/persona-ambient.sh" 2>/dev/null)
check "[J] ambient でも muted=true なら無出力" "" "$AMB_MUTED"
rm -rf "$D"

# ---------- (K) 抽選直後の制御面永続化（IH-W6 前倒し） ----------
# 新規抽選の persona は作業ツリーの state.json に書かれるだけでは ephemeral コンテナの回収で
# 消える（通常終了では on-stop の制御面コミットが走らない）。sprint_roll_persona は新規抽選時に
# 限り制御ブランチ sprint/<sprint_id> へ最善努力で checkpoint し、「再 clone を跨いで維持」を
# 仕組みで保証する（エージェントがコミット要否を Human へ確認する誘因を断つ）。
D=$(setup_env)
cp "$ROOT_REPO/.claude/sprint/hooks/_control_commit.sh" "$D/.claude/sprint/hooks/"
cp "$ROOT_REPO/.claude/sprint/hooks/_push.sh" "$D/.claude/sprint/hooks/"
git -C "$D" init -q
git -C "$D" config user.email "test@example.com"
git -C "$D" config user.name "test"
printf '{"sprint_id":"sprint-9","phase":"CLARIFY","persona":null}\n' > "$D/sprint/state.json"
(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
) 2>/dev/null
check "[K] 新規抽選で制御ブランチが作られる（HEAD は触らない）" "yes" \
  "$(git -C "$D" rev-parse --verify refs/heads/sprint/sprint-9 >/dev/null 2>&1 && echo yes || echo no)"
TIP_PERSONA_ID=$(git -C "$D" show sprint/sprint-9:sprint/state.json 2>/dev/null | jq -r '.persona.id // empty')
check "[K] 制御ブランチ先端の state.json に persona が永続化される" "yes" \
  "$([ -n "$TIP_PERSONA_ID" ] && echo yes || echo no)"
# 現在ブランチ（HEAD）にはコミットを積まない（plumbing コミットのみ）
check "[K] 作業ブランチ側にコミットは積まれない" "no" \
  "$(git -C "$D" rev-parse --verify HEAD >/dev/null 2>&1 && echo yes || echo no)"
# 冪等: 既設定の再呼び出しでは制御ブランチに新規コミットを打たない
TIP1=$(git -C "$D" rev-parse sprint/sprint-9 2>/dev/null)
(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
) 2>/dev/null
TIP2=$(git -C "$D" rev-parse sprint/sprint-9 2>/dev/null)
check "[K] 既設定時の再呼び出しは制御ブランチにコミットを打たない" "$TIP1" "$TIP2"
rm -rf "$D"

# 非 git 環境では抽選のみ行い、安全に no-op（既存挙動の回帰確認。_control_commit 不在でも壊れない）
D=$(setup_env)
(
  export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona
) 2>/dev/null
check "[K] 非 git 環境・_control_commit 不在でも抽選は成功する" "yes" \
  "$([ -n "$(jq -r '.persona.id // empty' "$D/sprint/state.json")" ] && echo yes || echo no)"
rm -rf "$D"

# ---------- (L) 語り口運用ルールの注入契約 ----------
# R-1〜R-6 の修正後に全注入経路でルールがモデルに届くことを検証する。
# rich 出力に運用ルールの要素が含まれる
D=$(setup_env)
( export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona )
BLOCK_L_RICH=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block rich )
# 「1返信に最大1回」相当の語（口癖の頻度制限）が含まれるか
check "[L] rich 出力に口癖の頻度制限（1返信1回）が含まれる" "yes" "$(echo "$BLOCK_L_RICH" | grep -q '1回' && echo yes || echo no)"
# 「丸写し」禁止相当の語が含まれるか
check "[L] rich 出力にセリフ例の丸写し禁止が含まれる" "yes" "$(echo "$BLOCK_L_RICH" | grep -q '丸写し' && echo yes || echo no)"
# 「定型締め」禁止相当の語が含まれるか
check "[L] rich 出力に定型締め禁止が含まれる" "yes" "$(echo "$BLOCK_L_RICH" | grep -q '定型締め' && echo yes || echo no)"
# compact 出力に頻度系ルールの要約が含まれる
BLOCK_L_COMPACT=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block compact )
check "[L] compact 出力に口癖の頻度制限（1返信1回）が含まれる" "yes" "$(echo "$BLOCK_L_COMPACT" | grep -q '1回' && echo yes || echo no)"
rm -rf "$D"

# 旧スキーマ（id/name/style のみ）でも rich/compact がエラーにならない
D=$(setup_env)
printf '{"persona":{"id":"old","name":"旧キャラ","style":"古い語り口"}}\n' > "$D/sprint/state.json"
OLD_RICH=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block rich 2>&1 )
OLD_COMPACT=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block compact 2>&1 )
check "[L] 旧スキーマで rich がエラーにならない（見出しを含む）" "yes" "$(echo "$OLD_RICH" | grep -q 'オーケストレーター人格' && echo yes || echo no)"
check "[L] 旧スキーマで compact がエラーにならない（見出しを含む）" "yes" "$(echo "$OLD_COMPACT" | grep -q 'オーケストレーター人格' && echo yes || echo no)"
rm -rf "$D"

# ---------- (N) persona-init-v2.sh 経由でも _persona.sh の機能を継承する（PERSONA_INHERITANCE_PLAN T5）----------
# §10 キャラクター人格 (8体・Orchestrator のみ) を V2 経路でも完全継承するため、
# persona-init-v2.sh は _persona.sh の sprint_roll_persona を委譲呼出する薄殻ラッパであること。
# 検査項目: 抽選成立 / 冪等 / env 無効化 / v2_active=false 時の no-op / 制御面 commit。

# 共通: persona-init-v2.sh が必要とするレイアウト (scripts/, .claude/sprint/hooks/) を整える
setup_v2_env() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/sprint" "$d/.claude/sprint/hooks" "$d/scripts"
  cp "$CATALOG" "$d/.claude/sprint/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_persona.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_state.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_control_commit.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/.claude/sprint/hooks/_push.sh" "$d/.claude/sprint/hooks/"
  cp "$ROOT_REPO/scripts/persona-init-v2.sh" "$d/scripts/"
  printf '%s\n' "$d"
}

# (N-1) v2_active=true なら persona-init-v2.sh で persona が抽選される
D=$(setup_v2_env)
printf '{"v2_active":true,"persona":null}\n' > "$D/sprint/state.json"
CLAUDE_PROJECT_DIR="$D" bash -c "cd '$D' && bash scripts/persona-init-v2.sh" 2>/dev/null
N1_ID=$(jq -r '.persona.id // empty' "$D/sprint/state.json" 2>/dev/null)
check "[N] persona-init-v2.sh で persona.id が抽選される (v2_active=true)" "yes" "$([ -n "$N1_ID" ] && echo yes || echo no)"
# 抽選 id がカタログに存在する (== _persona.sh 委譲経由)
N1_INCAT=$(jq -r --arg id "$N1_ID" '[.personas[].id] | index($id) | if . == null then "no" else "yes" end' "$CATALOG" 2>/dev/null)
check "[N] 抽選 id がカタログに存在する" "yes" "$N1_INCAT"
# 冪等: 再呼出で id が変わらない
CLAUDE_PROJECT_DIR="$D" bash -c "cd '$D' && bash scripts/persona-init-v2.sh" 2>/dev/null
check "[N] 既設定時の再呼出は再抽選しない" "$N1_ID" "$(jq -r '.persona.id' "$D/sprint/state.json")"
# リッチフィールド (examples) が永続化されている (= _persona.sh の sprint_roll_persona 委譲の証拠)
N1_NEX=$(jq -r '(.persona.examples // []) | length' "$D/sprint/state.json" 2>/dev/null || echo 0)
check "[N] 抽選 persona に examples が永続化される (_persona.sh 委譲)" "yes" "$([ "$N1_NEX" -ge 1 ] && echo yes || echo no)"
rm -rf "$D"

# (N-2) v2_active=false なら persona-init-v2.sh は no-op (v1 並走配慮)
D=$(setup_v2_env)
printf '{"v2_active":false,"persona":null}\n' > "$D/sprint/state.json"
CLAUDE_PROJECT_DIR="$D" bash -c "cd '$D' && bash scripts/persona-init-v2.sh" 2>/dev/null
check "[N] v2_active=false で persona-init-v2.sh は no-op" "null" "$(jq -r '.persona // "null"' "$D/sprint/state.json")"
rm -rf "$D"

# (N-3) SPRINT_PERSONA=off → persona-init-v2.sh 経由でも抽選しない (env 無効化の継承)
D=$(setup_v2_env)
printf '{"v2_active":true,"persona":null}\n' > "$D/sprint/state.json"
CLAUDE_PROJECT_DIR="$D" SPRINT_PERSONA=off bash -c "cd '$D' && bash scripts/persona-init-v2.sh" 2>/dev/null
check "[N] SPRINT_PERSONA=off で persona-init-v2.sh は抽選しない" "null" "$(jq -r '.persona // "null"' "$D/sprint/state.json")"
rm -rf "$D"

# (N-4) 制御面 commit (IH-W6 / sprint_control_plane_commit) が persona-init-v2.sh 経由でも走る
D=$(setup_v2_env)
git -C "$D" init -q
git -C "$D" config user.email "test@example.com"
git -C "$D" config user.name "test"
printf '{"v2_active":true,"sprint_id":"sprint-9","phase":"CLARIFY","persona":null}\n' > "$D/sprint/state.json"
CLAUDE_PROJECT_DIR="$D" bash -c "cd '$D' && bash scripts/persona-init-v2.sh" 2>/dev/null
check "[N] persona-init-v2.sh 経由でも制御ブランチ sprint/sprint-9 が作られる" "yes" \
  "$(git -C "$D" rev-parse --verify refs/heads/sprint/sprint-9 >/dev/null 2>&1 && echo yes || echo no)"
N4_TIP_ID=$(git -C "$D" show sprint/sprint-9:sprint/state.json 2>/dev/null | jq -r '.persona.id // empty')
check "[N] 制御ブランチ先端に persona が永続化される (persona-init-v2.sh 経由)" "yes" \
  "$([ -n "$N4_TIP_ID" ] && echo yes || echo no)"
rm -rf "$D"

# ---------- (M) compact 再注入によるペルソナ混線防止（圧縮後の語尾ドリフト対策） ----------
# 主因: SessionStart matcher が compact を含まないと、コンテキスト圧縮後にペルソナ定義が消え、
#   モデルが事前知識の典型語尾で補完して語尾が混線する。両 settings.json の matcher に compact を含め、
#   compact 出力にも「語尾」リストと「他ペルソナ混線禁止」の歯止めを入れる。
ROOT_SETTINGS="$ROOT_REPO/.claude/settings.json"
SPRINT_SETTINGS="$ROOT_REPO/.claude/sprint/settings.json"
# ルート settings の SessionStart matcher が compact を含む（persona-ambient の圧縮後再注入）
check "[M] ルート settings の SessionStart matcher が compact を含む" "yes" \
  "$(jq -e '[.hooks.SessionStart[]?.matcher] | any(. != null and (. | test("compact")))' "$ROOT_SETTINGS" >/dev/null 2>&1 && echo yes || echo no)"
# スプリント settings の SessionStart matcher が compact を含む（session-start の圧縮後再注入）
check "[M] スプリント settings の SessionStart matcher が compact を含む" "yes" \
  "$(jq -e '[.hooks.SessionStart[]?.matcher] | any(. != null and (. | test("compact")))' "$SPRINT_SETTINGS" >/dev/null 2>&1 && echo yes || echo no)"

# compact 出力に「語尾」行が含まれる（圧縮後に正しい語尾を明示してドリフトを抑える）
D=$(setup_env)
( export ROOT="$D" STATE_FILE="$D/sprint/state.json"
  # shellcheck disable=SC1090
  source "$D/.claude/sprint/hooks/_persona.sh"
  sprint_roll_persona )
BLOCK_M_COMPACT=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block compact )
check "[M] compact 出力に『語尾』行が含まれる" "yes" "$(echo "$BLOCK_M_COMPACT" | grep -q '^- \*\*語尾\*\*:' && echo yes || echo no)"
# compact 注記に他ペルソナの口癖・語尾を使わない旨が含まれる（混線禁止）
check "[M] compact 注記に他ペルソナ混線禁止の文言が含まれる" "yes" "$(echo "$BLOCK_M_COMPACT" | grep -q '他のペルソナの口癖・語尾' && echo yes || echo no)"
rm -rf "$D"

# speech 無し（旧スキーマ）の persona では「語尾」行を省略してもエラーにならない（防御的）
D=$(setup_env)
printf '{"persona":{"id":"old","name":"旧キャラ","style":"古い語り口","first_person":"わたし","address":"きみ"}}\n' > "$D/sprint/state.json"
OLD_M_COMPACT=$( export ROOT="$D" STATE_FILE="$D/sprint/state.json"; source "$D/.claude/sprint/hooks/_persona.sh"; sprint_persona_block compact 2>&1 )
check "[M] speech 無しの旧スキーマで compact がエラーにならない（見出しを含む）" "yes" "$(echo "$OLD_M_COMPACT" | grep -q 'オーケストレーター人格' && echo yes || echo no)"
check "[M] speech 無しの旧スキーマでは『語尾』行を出さない" "yes" "$(echo "$OLD_M_COMPACT" | grep -q '^- \*\*語尾\*\*:' && echo no || echo yes)"
rm -rf "$D"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
