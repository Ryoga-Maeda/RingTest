#!/usr/bin/env bash
# tests/test_deploy_sprint.sh — scripts/deploy-sprint.sh の契約（回帰防止）テスト
#
# 位置づけ: レビュー指摘 #7「deploy-sprint.sh 自体のテストが無い」への対応。
#   本スクリプトは「アーキテクチャは同期・プロジェクト状態は保全」という最重要契約を担う。
#   レビューで手検証した契約（#2/#3/#6/#10 の回帰防止を含む）を自動化し、現行仕様を固定する。
#
# 検証する契約（development/deploy-sprint-review-plan.md #7 の列挙に対応）:
#   1) 初回展開: 空 git リポジトリへ展開 → exit 0・stdout=changed・主要ファイル存在
#   2) プロジェクト状態の保全: 既存 PRODUCT.md / state.json の独自内容が上書きされない
#   3) 冪等性: コミット後に同一 SOURCE で再展開 → porcelain 空・stdout=unchanged
#   4) 未追跡ファイル非配布（#3 回帰）: SOURCE の未追跡ファイルが TARGET に混入しない
#   5) dirty TARGET での --commit 中断（#2 回帰）: exit 4・未コミットファイルを巻き込まない
#   6) .gitignore 整備の冪等性: 2回展開しても必須エントリが重複追記されない
#   7) 引数検証（#10 回帰）: --target 値なし → exit 2 と usage 表示
#   8) settings.json マージ（#6 回帰）: language/独自キー保全・hooks 更新・null 非混入
#   9) RUNNING 状態の既存導入先への再展開（A-1 回帰）: 自動検証が誤 FAIL しない
#  10) 隔離検査の単語一致（-w 回帰）: CLAUDE.md の「R18」等を誤検知せず、規律識別子 R1 は検出する
#  11) jq preflight: パス指定でファイルを開けない jq（snap 模擬）を exit 4 で早期検出する
#  12) settings マージ警告: 失敗時の警告に jq の原因（stderr）が含まれる
#  13) state.json スキーマ移行: 旧スキーマ（.usage あり・.resilience なし）の既存導入先へ
#      再展開すると、進行状態を保全したままスキーマが現行へ移行され、展開後検証が PASS する。
#      かつ再展開は冪等（2回目は差分ゼロ）。
#  14) budget.json 構造同期: 旧構造（撤去済みキー・改変値・余剰トップレベルキーを持つ）の既存
#      導入先へ再展開すると、budget.json がテンプレートの最新構造・値へ上書きされる
#      （撤去キーは消え・新規キーは入り・値はテンプレート一致）。かつ再展開は冪等。
#
# 環境注意:
#   - SOURCE はテンプレート本体を直接使わず /tmp への git clone を使う
#     （ケース4で SOURCE 側に未追跡ファイルを置くため。本体リポジトリを汚さない）。
#   - 一時リポジトリには commit.gpgsign false と user.name / user.email を必ず設定する
#     （署名が通らない環境でも、CI・ローカル WSL でも動くようローカル設定として行う）。
#   - rsync の有無に依存しない（フォールバック経路でも同契約が成り立つことを検証する）。
#   - deploy-sprint.sh は展開後に TARGET で test_isolation.sh を自走するため時間がかかる。
#     使い回せる SOURCE clone は1回だけ作り、TARGET だけケースごとに作り直す。
#
# set -e は付けない（exit コードを明示的に捕捉して検証するため）。
set -uo pipefail

PASS=0
FAIL=0

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 一時作業領域（全ケースをこの配下に作り、終了時に一括削除）。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# SOURCE はテンプレート本体の /tmp clone（本体を汚さない・未追跡ファイルを置けるよう作業ツリー込み）。
SOURCE="$WORK/source"
git clone -q "$SCRIPT_DIR" "$SOURCE"
# git clone は HEAD（コミット済み）しか含まないため、未コミットの修正もテスト対象になるよう
# 本体の作業ツリー版を clone へ上書き反映する（契約テストは「これからコミットする版」を検証する）。
# どちらも追跡済みファイルなので、merge_dir はこのコピー版を配布する。
cp "$SCRIPT_DIR/scripts/deploy-sprint.sh" "$SOURCE/scripts/deploy-sprint.sh"
cp "$SCRIPT_DIR/tests/test_isolation.sh" "$SOURCE/tests/test_isolation.sh"
DEPLOY="$SOURCE/scripts/deploy-sprint.sh"

# 空の git リポジトリを TARGET として作る補助（署名無効化はこの一時リポジトリのローカル設定）。
init_target() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config user.email deploy-test@example.com
  git -C "$dir" config user.name "Deploy Test"
}

echo "=== test_deploy_sprint.sh（deploy-sprint.sh 契約テスト）==="

# --- シナリオ1: 初回展開 ---
echo ""
echo "シナリオ1: 初回展開（空 git リポジトリへ）"
T1="$WORK/t1"
init_target "$T1"
OUT1=""; EC1=0
OUT1="$(bash "$DEPLOY" --target "$T1" --source "$SOURCE" --quiet 2>/dev/null)" || EC1=$?
check "初回展開: exit 0" "0" "$EC1"
check "初回展開: stdout が changed" "changed" "$OUT1"
# §11.2 R-1: v1 RULES.md は削除済み。V2 規律は L1 フレームワークヘッダに移転。
check "初回展開: .claude/agents/_prefix/L1-framework-header.md が存在" "yes" "$([ -f "$T1/.claude/agents/_prefix/L1-framework-header.md" ] && echo yes || echo no)"
check "初回展開: .claude/sprint/RULES.md は配布されない" "no" "$([ -f "$T1/.claude/sprint/RULES.md" ] && echo yes || echo no)"
# §11.2 R-2a-2: scripts/sprint-runner.sh (v1) は削除済み。V2 では phase-advance スクリプトが配布される。
check "初回展開: scripts/sprint-runner.sh は配布されない" "no" "$([ -e "$T1/scripts/sprint-runner.sh" ] && echo yes || echo no)"
check "初回展開: scripts/phase-advance-eval.sh が存在" "yes" "$([ -f "$T1/scripts/phase-advance-eval.sh" ] && echo yes || echo no)"
check "初回展開: scripts/phase-advance-apply.sh が存在" "yes" "$([ -f "$T1/scripts/phase-advance-apply.sh" ] && echo yes || echo no)"
check "初回展開: sprint/state.json が存在" "yes" "$([ -f "$T1/sprint/state.json" ] && echo yes || echo no)"
check "初回展開: state.json は run_state=OFF へ正規化" "OFF" "$(jq -r '.run_state' "$T1/sprint/state.json" 2>/dev/null)"
# テンプレート専用ツールは配らない（merge_dir の除外）。
check "初回展開: deploy-sprint.sh は配布されない" "no" "$([ -e "$T1/scripts/deploy-sprint.sh" ] && echo yes || echo no)"

# --- シナリオ2: プロジェクト状態の保全 ---
echo ""
echo "シナリオ2: プロジェクト状態の保全（既存の独自内容を上書きしない）"
T2="$WORK/t2"
init_target "$T2"
mkdir -p "$T2/sprint"
printf 'MY OWN PRODUCT CONTENT\n' > "$T2/sprint/PRODUCT.md"
# 独自内容の state.json（進行途中を模す）。展開後も保全されること（無いときだけ初期化する契約）。
printf '{"sprint_id":"my-own-sprint","phase":"BUILD","run_state":"RUNNING","custom":"keep"}\n' > "$T2/sprint/state.json"
bash "$DEPLOY" --target "$T2" --source "$SOURCE" --quiet >/dev/null 2>&1
check "状態保全: PRODUCT.md の独自内容が保持される" "MY OWN PRODUCT CONTENT" "$(cat "$T2/sprint/PRODUCT.md")"
check "状態保全: state.json の sprint_id が保持される" "my-own-sprint" "$(jq -r '.sprint_id' "$T2/sprint/state.json" 2>/dev/null)"
check "状態保全: state.json の独自キーが保持される" "keep" "$(jq -r '.custom' "$T2/sprint/state.json" 2>/dev/null)"

# --- シナリオ3: 冪等性 ---
echo ""
echo "シナリオ3: 冪等性（コミット後に同一 SOURCE で再展開 → 差分ゼロ）"
T3="$WORK/t3"
init_target "$T3"
bash "$DEPLOY" --target "$T3" --source "$SOURCE" --quiet >/dev/null 2>&1
git -C "$T3" add -A
git -C "$T3" commit -q -m "初回展開"
OUT3=""; EC3=0
OUT3="$(bash "$DEPLOY" --target "$T3" --source "$SOURCE" --quiet 2>/dev/null)" || EC3=$?
check "冪等性: 再展開も exit 0" "0" "$EC3"
check "冪等性: stdout が unchanged" "unchanged" "$OUT3"
check "冪等性: git status --porcelain が空" "" "$(git -C "$T3" status --porcelain)"

# --- シナリオ4: 未追跡ファイル非配布（#3 回帰） ---
echo ""
echo "シナリオ4: 未追跡ファイル非配布（SOURCE の未追跡ファイルが TARGET に混入しない）"
# SOURCE（clone）の共有・専有ディレクトリに未追跡ファイルを置く。
printf 'leaked\n' > "$SOURCE/scripts/UNTRACKED_SCRIPT.sh"
printf 'leaked\n' > "$SOURCE/.claude/sprint/UNTRACKED_SPRINT.txt"
T4="$WORK/t4"
init_target "$T4"
bash "$DEPLOY" --target "$T4" --source "$SOURCE" --quiet >/dev/null 2>&1
check "未追跡非配布: scripts/ の未追跡が混入しない" "no" "$([ -e "$T4/scripts/UNTRACKED_SCRIPT.sh" ] && echo yes || echo no)"
check "未追跡非配布: .claude/sprint/ の未追跡が混入しない" "no" "$([ -e "$T4/.claude/sprint/UNTRACKED_SPRINT.txt" ] && echo yes || echo no)"
# SOURCE clone を後続ケースのため元のクリーン状態へ戻す。
rm -f "$SOURCE/scripts/UNTRACKED_SCRIPT.sh" "$SOURCE/.claude/sprint/UNTRACKED_SPRINT.txt"

# --- シナリオ5: dirty TARGET での --commit 中断（#2 回帰） ---
echo ""
echo "シナリオ5: dirty TARGET での --commit 中断（exit 4・無関係な変更を巻き込まない）"
T5="$WORK/t5"
init_target "$T5"
# 先に一度展開してコミットし、クリーンな初期状態を作る。
bash "$DEPLOY" --target "$T5" --source "$SOURCE" --quiet >/dev/null 2>&1
git -C "$T5" add -A
git -C "$T5" commit -q -m "初回展開"
# 無関係な未コミットファイルを置く（dirty 状態）。
printf 'work in progress\n' > "$T5/user-wip.txt"
EC5=0
bash "$DEPLOY" --target "$T5" --source "$SOURCE" --commit --quiet >/dev/null 2>&1 || EC5=$?
check "dirty --commit: exit 4 で中断" "4" "$EC5"
# 中断したので user-wip.txt は未追跡のまま残り、コミットには含まれない。
check "dirty --commit: 無関係ファイルが未追跡のまま残る" "?? user-wip.txt" "$(git -C "$T5" status --porcelain | grep 'user-wip.txt')"
check "dirty --commit: user-wip.txt を含むコミットが作られていない" "0" "$(git -C "$T5" log --all --oneline -- user-wip.txt | wc -l | tr -d ' ')"

# --- シナリオ6: .gitignore 整備の冪等性 ---
echo ""
echo "シナリオ6: .gitignore 整備の冪等性（2回展開しても重複追記しない）"
T6="$WORK/t6"
init_target "$T6"
bash "$DEPLOY" --target "$T6" --source "$SOURCE" --quiet >/dev/null 2>&1
bash "$DEPLOY" --target "$T6" --source "$SOURCE" --quiet >/dev/null 2>&1
# 必須エントリがそれぞれちょうど1回だけ存在すること（完全一致行で数える）。
dup_found=0
for entry in ".claude/worktrees/" ".claude/settings.local.json" "sprint/.session-out.log" \
             "sprint/*.lock" "sprint/*.lock.d/" "sprint/tasks/*.status.json" \
             "sprint/tasks/*.lock" "sprint/tasks/*.lock.d/"; do
  cnt=$(grep -cxF "$entry" "$T6/.gitignore" 2>/dev/null || echo 0)
  [ "$cnt" -eq 1 ] || { echo "    （重複検出: '$entry' が $cnt 行）"; dup_found=1; }
done
check ".gitignore 冪等: 各必須エントリがちょうど1回" "0" "$dup_found"

# --- シナリオ7: 引数検証（#10 回帰） ---
echo ""
echo "シナリオ7: 引数検証（--target 値なし → exit 2 と usage 表示）"
EC7=0
ERR7="$(bash "$DEPLOY" --target 2>&1 >/dev/null)" || EC7=$?
check "引数検証: --target 値なしで exit 2" "2" "$EC7"
check "引数検証: usage が表示される" "yes" "$(printf '%s' "$ERR7" | grep -q '使い方' && echo yes || echo no)"

# --- シナリオ8: settings.json マージ（#6 回帰） ---
echo ""
echo "シナリオ8: settings.json マージ（language/独自キー保全・hooks 更新・null 非混入）"
T8="$WORK/t8"
init_target "$T8"
mkdir -p "$T8/.claude"
# 導入先固有の language=en と独自トップレベルキーを置く。hooks は更新される側。
printf '{ "language": "en", "myCustomKey": "keep-me", "hooks": { "Stop": [] } }\n' > "$T8/.claude/settings.json"
bash "$DEPLOY" --target "$T8" --source "$SOURCE" --quiet >/dev/null 2>&1
check "settings マージ: language=en が保全される" "en" "$(jq -r '.language' "$T8/.claude/settings.json" 2>/dev/null)"
check "settings マージ: 独自キーが保全される" "keep-me" "$(jq -r '.myCustomKey' "$T8/.claude/settings.json" 2>/dev/null)"
check "settings マージ: hooks.SessionStart が更新される" "yes" \
  "$(jq -e '.hooks.SessionStart' "$T8/.claude/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
# テンプレート所有キー（_hooks_note）が SOURCE 値で伝搬し、null は混入しない（#6 の select(.value!=null)）。
check "settings マージ: _hooks_note が伝搬される" "true" "$(jq 'has("_hooks_note")' "$T8/.claude/settings.json" 2>/dev/null)"
check "settings マージ: null 値が混入しない" "0" "$(jq '[.. | select(. == null)] | length' "$T8/.claude/settings.json" 2>/dev/null)"

# --- シナリオ9: 既存 run_state=RUNNING の TARGET への再展開で自動検証が PASS ---
echo ""
echo "シナリオ9: RUNNING 状態の既存導入先への再展開（自動検証が誤 FAIL しない）"
# 初回展開 → コミット → run_state を RUNNING に書き換え → 再展開 → exit 0 で完走すること。
# tests/test_isolation.sh の A-1 修正（期待値を元値基準に）がないと exit 3 で落ちる。
# （作業ツリー版の test_isolation.sh は冒頭で SOURCE clone へ反映済み。）
T9="$WORK/t9"
init_target "$T9"
# 初回展開（state.json が初期化される）。
bash "$DEPLOY" --target "$T9" --source "$SOURCE" --quiet >/dev/null 2>&1
git -C "$T9" add -A
git -C "$T9" commit -q -m "初回展開"
# state.json の run_state を RUNNING（進行中スプリント）に書き換え。
jq '.run_state = "RUNNING" | .phase = "EXECUTE"' "$T9/sprint/state.json" > "$T9/sprint/state.json.tmp" \
  && mv "$T9/sprint/state.json.tmp" "$T9/sprint/state.json"
# 再展開を実行。A-1 修正後は exit 0 で完走し、出力に「隔離テスト: FAIL」が含まれない。
EC9=0
OUT9_ERR="$(bash "$DEPLOY" --target "$T9" --source "$SOURCE" --quiet 2>&1 >/dev/null)" || EC9=$?
check "RUNNING 再展開: exit 0 で完走" "0" "$EC9"
check "RUNNING 再展開: 出力に「隔離テスト: FAIL」が含まれない" "no" \
  "$(printf '%s' "$OUT9_ERR" | grep -q '隔離テスト: FAIL' && echo yes || echo no)"
# 再展開後も run_state は保全される（RUNNING のまま。state.json は既存保全の契約）。
check "RUNNING 再展開: state.json の run_state が保全される" "RUNNING" \
  "$(jq -r '.run_state' "$T9/sprint/state.json" 2>/dev/null)"

# --- シナリオ10: 隔離検査の単語一致（-w 回帰） ---
echo ""
echo "シナリオ10: 隔離検査の単語一致（CLAUDE.md の R18 を誤検知せず、規律識別子 R1 は検出）"
# 実例: R18 コンテンツ方針を書いた導入先 CLAUDE.md が、部分一致 grep により R1 と誤検知された。
T10="$WORK/t10"
init_target "$T10"
printf '# CLAUDE.md\n\n## コンテンツ方針\nR18作品（ノクターン等）は年齢確認ダイアログを表示する。\n' > "$T10/CLAUDE.md"
git -C "$T10" add -A
git -C "$T10" commit -q -m "R18 ポリシーを含む CLAUDE.md"
EC10=0
OUT10_ERR="$(bash "$DEPLOY" --target "$T10" --source "$SOURCE" --quiet 2>&1 >/dev/null)" || EC10=$?
check "R18 誤検知: R18 を含む CLAUDE.md でも exit 0 で完走" "0" "$EC10"
check "R18 誤検知: 出力に「隔離テスト: FAIL」が含まれない" "no" \
  "$(printf '%s' "$OUT10_ERR" | grep -q '隔離テスト: FAIL' && echo yes || echo no)"
# 検出力の維持: 規律識別子そのもの（単語としての R1）は引き続き検出して exit 3 になる。
printf '\n禁止事項: R1 に違反するコード変更をしない。\n' >> "$T10/CLAUDE.md"
EC10b=0
bash "$DEPLOY" --target "$T10" --source "$SOURCE" --quiet >/dev/null 2>&1 || EC10b=$?
check "R1 検出力: 規律識別子 R1 を含む CLAUDE.md は exit 3 で検出" "3" "$EC10b"

# --- シナリオ11: jq preflight（snap 版 jq の模擬） ---
echo ""
echo "シナリオ11: jq preflight（パス指定でファイルを開けない jq を exit 4 で早期検出）"
# snap 版 jq は隔離マウント名前空間により /mnt/c 等の実在ファイルに ENOENT を返す。
# これを「絶対パス引数を常に Could not open file にする」シムで模擬する（stdin は本物へ委譲）。
SHIM_DIR="$WORK/jqshim"
mkdir -p "$SHIM_DIR"
REAL_JQ="$(command -v jq)"
cat > "$SHIM_DIR/jq" <<SHIM_EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    /*) echo "jq: error: Could not open file \$a: No such file or directory" >&2; exit 2 ;;
  esac
done
exec "$REAL_JQ" "\$@"
SHIM_EOF
chmod +x "$SHIM_DIR/jq"
T11="$WORK/t11"
init_target "$T11"
EC11=0
OUT11_ERR="$(PATH="$SHIM_DIR:$PATH" bash "$DEPLOY" --target "$T11" --source "$SOURCE" --quiet 2>&1 >/dev/null)" || EC11=$?
check "jq preflight: 壊れた jq を exit 4 で中断" "4" "$EC11"
check "jq preflight: snap 版 jq の可能性と対処を案内する" "yes" \
  "$(printf '%s' "$OUT11_ERR" | grep -q 'snap 版 jq' && echo yes || echo no)"
# preflight は同期処理より前に走るため、TARGET には何も書き込まれていない（.git のみ）。
check "jq preflight: 中断時に TARGET へ書き込みが無い" "" "$(ls -A "$T11" | grep -v '^\.git$')"

# --- シナリオ12: settings マージ警告に原因（jq stderr）が含まれる ---
echo ""
echo "シナリオ12: settings マージ失敗の警告に jq の原因が含まれる（握りつぶし防止）"
# 導入先の settings.json を不正 JSON にしてマージを失敗させ、警告行に jq のエラー文言が
# 添えられることを確認する（以前は 2>/dev/null で原因が見えず診断が遅れた）。
T12="$WORK/t12"
init_target "$T12"
mkdir -p "$T12/.claude"
printf '{ this is not json\n' > "$T12/.claude/settings.json"
OUT12_ERR="$(bash "$DEPLOY" --target "$T12" --source "$SOURCE" --quiet 2>&1 >/dev/null)" || true
WARN12="$(printf '%s' "$OUT12_ERR" | grep '警告: settings.json のマージに失敗' || true)"
check "settings 警告: 警告行が出る" "yes" "$([ -n "$WARN12" ] && echo yes || echo no)"
check "settings 警告: 警告に jq の原因が含まれる" "yes" \
  "$(printf '%s' "$WARN12" | grep -qiE 'parse error|Invalid|error' && echo yes || echo no)"

# --- シナリオ13: state.json スキーマ移行（旧スキーマの既存導入先への再展開） ---
echo ""
echo "シナリオ13: state.json スキーマ移行（.usage 撤去・.resilience 追加を既存ファイルへ反映）"
# 実例: 使用量撤去（.usage 削除・.resilience 追加）より前に展開済みの導入先（narou-reader 等）は、
#   古いスキーマの state.json が保全されたまま展開後検証にかかり、ちょうど2件 FAIL していた
#   （"resilience フィールドが存在"=false / "usage フィールドが無い"=true）。
T13="$WORK/t13"
init_target "$T13"
# 先に現行版で初回展開してコミットし、その後 state.json を「旧スキーマ＋進行状態」へ巻き戻す。
bash "$DEPLOY" --target "$T13" --source "$SOURCE" --quiet >/dev/null 2>&1
git -C "$T13" add -A
git -C "$T13" commit -q -m "初回展開"
# 旧スキーマを模す: .resilience を削除し、レジリエンス系を .usage 配下へ退避（移設前の姿）。
#   併せて進行状態（RUNNING/BUILD/タスク/独自キー）を持たせ、保全されることを検証する。
jq 'del(.resilience)
    | .usage = { consumed_pct: 42, consecutive_tool_failures: 2,
                 persist_failed: true, persist_failed_branches: ["wip/foo"] }
    | .run_state = "RUNNING" | .phase = "BUILD" | .sprint_id = "downstream-sprint"
    | .tasks = { "T-1": { "status": "doing" } }
    | .my_downstream_key = "keep-me"' \
   "$T13/sprint/state.json" > "$T13/sprint/state.json.tmp" \
   && mv "$T13/sprint/state.json.tmp" "$T13/sprint/state.json"
git -C "$T13" add -A
git -C "$T13" commit -q -m "旧スキーマ＋進行状態へ巻き戻し"
# 再展開: 移行後は展開後検証が PASS し exit 0 で完走する（旧版だと exit 3 で落ちていた）。
EC13=0
OUT13_ERR="$(bash "$DEPLOY" --target "$T13" --source "$SOURCE" --quiet 2>&1 >/dev/null)" || EC13=$?
check "スキーマ移行: 再展開が exit 0 で完走" "0" "$EC13"
check "スキーマ移行: 出力に「隔離テスト: FAIL」が含まれない" "no" \
  "$(printf '%s' "$OUT13_ERR" | grep -q '隔離テスト: FAIL' && echo yes || echo no)"
# 移行結果: .resilience が新設され、.usage は除去される。
check "スキーマ移行: .resilience が新設される" "true" \
  "$(jq 'has("resilience")' "$T13/sprint/state.json" 2>/dev/null)"
check "スキーマ移行: .usage が除去される" "false" \
  "$(jq 'has("usage")' "$T13/sprint/state.json" 2>/dev/null)"
# レジリエンス系フィールドは旧 .usage 配下から救出される（消失させない）。
check "スキーマ移行: consecutive_tool_failures を救出" "2" \
  "$(jq -r '.resilience.consecutive_tool_failures' "$T13/sprint/state.json" 2>/dev/null)"
check "スキーマ移行: persist_failed を救出" "true" \
  "$(jq -r '.resilience.persist_failed' "$T13/sprint/state.json" 2>/dev/null)"
check "スキーマ移行: persist_failed_branches を救出" "wip/foo" \
  "$(jq -r '.resilience.persist_failed_branches[0]' "$T13/sprint/state.json" 2>/dev/null)"
# 進行状態・独自キーは保全される（移行はスキーマ形状のみを整える）。
check "スキーマ移行: run_state が保全される" "RUNNING" \
  "$(jq -r '.run_state' "$T13/sprint/state.json" 2>/dev/null)"
check "スキーマ移行: phase が保全される" "BUILD" \
  "$(jq -r '.phase' "$T13/sprint/state.json" 2>/dev/null)"
check "スキーマ移行: sprint_id が保全される" "downstream-sprint" \
  "$(jq -r '.sprint_id' "$T13/sprint/state.json" 2>/dev/null)"
check "スキーマ移行: tasks が保全される" "doing" \
  "$(jq -r '.tasks["T-1"].status' "$T13/sprint/state.json" 2>/dev/null)"
check "スキーマ移行: 導入先固有キーが保全される" "keep-me" \
  "$(jq -r '.my_downstream_key' "$T13/sprint/state.json" 2>/dev/null)"
# 冪等性: 移行をコミットしてから再展開すると差分ゼロ（churn しない）。
git -C "$T13" add -A
git -C "$T13" commit -q -m "スキーマ移行を反映"
OUT13b=""; EC13b=0
OUT13b="$(bash "$DEPLOY" --target "$T13" --source "$SOURCE" --quiet 2>/dev/null)" || EC13b=$?
check "スキーマ移行: 移行後の再展開は unchanged（冪等）" "unchanged" "$OUT13b"
check "スキーマ移行: 移行後の git status が空（冪等）" "" "$(git -C "$T13" status --porcelain)"

# --- シナリオ14: budget.json 構造同期（旧構造の既存導入先への再展開） ---
echo ""
echo "シナリオ14: budget.json 構造同期（撤去済みキー削除・改変値の上書き・テンプレート構造へ追従）"
# 実例: max_parallelism から旧モデル名キー（opus/sonnet/haiku）を撤去する／five_hour_limit_tokens
#   を足し引きする等の構造変更後、scaffold_if_absent（無いときだけ作成）では既存導入先に
#   構造変更が永久に伝搬しなかった。budget.json は進行状態を持たない純設定なので常に同期する。
T14="$WORK/t14"
init_target "$T14"
bash "$DEPLOY" --target "$T14" --source "$SOURCE" --quiet >/dev/null 2>&1
git -C "$T14" add -A
git -C "$T14" commit -q -m "初回展開"
# 旧構造を模す: 撤去済みのモデル名キー・改変したティア値・余剰トップレベルキーを持たせる。
jq '.max_parallelism.opus = 1 | .max_parallelism.sonnet = 3 | .max_parallelism.haiku = 3
    | .max_parallelism.high = 99
    | .obsolete_top_level_key = true' \
   "$T14/sprint/budget.json" > "$T14/sprint/budget.json.tmp" \
   && mv "$T14/sprint/budget.json.tmp" "$T14/sprint/budget.json"
git -C "$T14" add -A
git -C "$T14" commit -q -m "旧構造の budget.json へ巻き戻し"
# 再展開: budget.json はテンプレートの最新構造・値へ上書きされ exit 0 で完走する。
EC14=0
OUT14_ERR="$(bash "$DEPLOY" --target "$T14" --source "$SOURCE" --quiet 2>&1 >/dev/null)" || EC14=$?
check "budget 同期: 再展開が exit 0 で完走" "0" "$EC14"
check "budget 同期: 出力に「隔離テスト: FAIL」が含まれない" "no" \
  "$(printf '%s' "$OUT14_ERR" | grep -q '隔離テスト: FAIL' && echo yes || echo no)"
# 撤去済みキーは消える（scaffold_if_absent では残り続けていた）。
check "budget 同期: 撤去キー max_parallelism.opus が消える" "null" \
  "$(jq -r '.max_parallelism.opus // "null"' "$T14/sprint/budget.json" 2>/dev/null)"
check "budget 同期: 余剰トップレベルキーが消える" "false" \
  "$(jq 'has("obsolete_top_level_key")' "$T14/sprint/budget.json" 2>/dev/null)"
# 改変された値はテンプレート値へ上書きされる（high をテンプレートと突き合わせる）。
SRC_HIGH="$(jq -r '.max_parallelism.high' "$SOURCE/sprint/budget.json" 2>/dev/null)"
check "budget 同期: 改変値 max_parallelism.high がテンプレート値へ上書き" "$SRC_HIGH" \
  "$(jq -r '.max_parallelism.high' "$T14/sprint/budget.json" 2>/dev/null)"
# 全体としてテンプレートと構造・値が完全一致する（純テンプレ同期）。
check "budget 同期: budget.json がテンプレートと完全一致" "match" \
  "$([ "$(jq -S . "$T14/sprint/budget.json" 2>/dev/null)" = "$(jq -S . "$SOURCE/sprint/budget.json" 2>/dev/null)" ] && echo match || echo differ)"
# 冪等性: 同期をコミットしてから再展開すると差分ゼロ。
git -C "$T14" add -A
git -C "$T14" commit -q -m "budget.json 同期を反映"
OUT14b=""; EC14b=0
OUT14b="$(bash "$DEPLOY" --target "$T14" --source "$SOURCE" --quiet 2>/dev/null)" || EC14b=$?
check "budget 同期: 同期後の再展開は unchanged（冪等）" "unchanged" "$OUT14b"
check "budget 同期: 同期後の git status が空（冪等）" "" "$(git -C "$T14" status --porcelain)"

# --- 結果 ---
echo ""
echo "================================"
echo "deploy-sprint 契約テスト結果: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
