#!/usr/bin/env bash
# tests/test_check_consistency.sh — scripts/check-consistency.sh の単体テスト（ARCHITECTURE_RETROSPECTIVE 1-1）
# state.json の主張と git 実体の乖離を検出して警告（exit 3）し、整合時は OK（exit 0）を返すことを検証する。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/sprint"
cp "$ROOT_REPO/scripts/check-consistency.sh" "$T/scripts/"

git -C "$T" init -q
git -C "$T" config user.email t@t.com; git -C "$T" config user.name T
git -C "$T" config commit.gpgsign false
echo base > "$T/README"; git -C "$T" add -A; git -C "$T" commit -qm init
HEAD_COMMIT=$(git -C "$T" rev-parse HEAD)

run() { CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/check-consistency.sh" >/dev/null 2>&1; echo $?; }
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

echo "=== test_check_consistency.sh (1-1) ==="

# 1) 整合: merged=true で merge_commit が HEAD の ancestor → OK(0)
jq -n --arg c "$HEAD_COMMIT" '{tasks:{"task-001":{status:"COMPLETE",merged:true,merge_commit:$c}}}' > "$T/sprint/state.json"
expect "[整合] merged=true で merge_commit が HEAD ancestor → exit 0" 0 "$(run)"

# 2) 乖離: IN_PROGRESS で存在しないブランチ → 警告(3)
jq -n '{tasks:{"task-002":{status:"IN_PROGRESS",branch:"worktree-task-002"}}}' > "$T/sprint/state.json"
expect "[乖離] IN_PROGRESS で branch 不在 → exit 3" 3 "$(run)"

# 3) 整合: IN_PROGRESS で実在ブランチ → OK(0)
git -C "$T" branch worktree-task-003 HEAD
jq -n '{tasks:{"task-003":{status:"IN_PROGRESS",branch:"worktree-task-003"}}}' > "$T/sprint/state.json"
expect "[整合] IN_PROGRESS で branch 実在 → exit 0" 0 "$(run)"

# 4) 乖離: COMPLETE(未マージ) で branch も last_commit も無い → 警告(3)
jq -n '{tasks:{"task-004":{status:"COMPLETE",merged:false,branch:"worktree-task-004",last_commit:""}}}' > "$T/sprint/state.json"
expect "[乖離] COMPLETE 未マージで成果不在 → exit 3" 3 "$(run)"

# 5) 整合: COMPLETE(未マージ) で branch 実在 → OK(0)
git -C "$T" branch worktree-task-005 HEAD
jq -n '{tasks:{"task-005":{status:"COMPLETE",merged:false,branch:"worktree-task-005"}}}' > "$T/sprint/state.json"
expect "[整合] COMPLETE 未マージで branch 実在 → exit 0" 0 "$(run)"

# 6) 乖離: merged=true だが merge_commit/last_commit/branch いずれも実在しない → 警告(3)
jq -n '{tasks:{"task-006":{status:"COMPLETE",merged:true,merge_commit:"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",last_commit:"",branch:"worktree-task-006"}}}' > "$T/sprint/state.json"
expect "[乖離] merged=true だが成果が全て不在 → exit 3" 3 "$(run)"

# --- IH-W9: --heal による自動降格（オプトイン） ---
heal() { CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/check-consistency.sh" --heal >/dev/null 2>&1; }
# W9-1) COMPLETE 未マージで成果喪失 + --heal → IN_PROGRESS/RED へ降格
jq -n '{tasks:{"task-009":{status:"COMPLETE",merged:false,branch:"worktree-task-009",last_commit:""}}}' > "$T/sprint/state.json"
heal
expect "[W9] --heal で status=IN_PROGRESS へ降格" "IN_PROGRESS" "$(jq -r '.tasks["task-009"].status' "$T/sprint/state.json")"
expect "[W9] --heal で tdd_phase=RED へ降格" "RED" "$(jq -r '.tasks["task-009"].tdd_phase' "$T/sprint/state.json")"
expect "[W9] --heal で merged=false に正規化" "false" "$(jq -r '.tasks["task-009"].merged' "$T/sprint/state.json")"

# W9-2) SPRINT_CONSISTENCY_HEAL=1 でも同様に降格
jq -n '{tasks:{"task-012":{status:"COMPLETE",merged:false,branch:"worktree-task-012",last_commit:""}}}' > "$T/sprint/state.json"
CLAUDE_PROJECT_DIR="$T" SPRINT_CONSISTENCY_HEAL=1 bash "$T/scripts/check-consistency.sh" >/dev/null 2>&1
expect "[W9] env SPRINT_CONSISTENCY_HEAL=1 でも降格" "IN_PROGRESS" "$(jq -r '.tasks["task-012"].status' "$T/sprint/state.json")"

# W9-3) --heal なしは破壊的変更をしない（既定は警告のみ）
jq -n '{tasks:{"task-010":{status:"COMPLETE",merged:false,branch:"worktree-task-010",last_commit:""}}}' > "$T/sprint/state.json"
CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/check-consistency.sh" >/dev/null 2>&1
expect "[W9] --heal なしは status を変えない（COMPLETE のまま）" "COMPLETE" "$(jq -r '.tasks["task-010"].status' "$T/sprint/state.json")"

# W9-4) merged=true の成果喪失は --heal でも降格しない（エスカレーション扱い）
jq -n '{tasks:{"task-011":{status:"COMPLETE",merged:true,merge_commit:"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",last_commit:"",branch:"worktree-task-011"}}}' > "$T/sprint/state.json"
heal
expect "[W9] merged=true 喪失は --heal でも降格しない" "COMPLETE" "$(jq -r '.tasks["task-011"].status' "$T/sprint/state.json")"

# W9-5) 整合状態で --heal は何も壊さない（COMPLETE 実在ブランチは維持）
git -C "$T" branch worktree-task-013 HEAD
jq -n '{tasks:{"task-013":{status:"COMPLETE",merged:false,branch:"worktree-task-013"}}}' > "$T/sprint/state.json"
heal
expect "[W9] 整合状態は --heal でも維持" "COMPLETE" "$(jq -r '.tasks["task-013"].status' "$T/sprint/state.json")"

# --- 成果物の機械照合（produces: narou-reader feedback A / §3 P1）---
# 「state は COMPLETE だが宣言した成果物ファイルが成果 ref に無い」を機械検出する。
# 成果物を worktree-task-020 ブランチにのみ載せ、main は未マージのままにする
# （sprint/ を git に巻き込まないため featdir だけを add する。reset --hard で sprint/ を
#  消すと後続テストの state.json 書込先ディレクトリが失われるので使わない）。
git -C "$T" checkout -q -b worktree-task-020
mkdir -p "$T/featdir"; echo x > "$T/featdir/Feature.kt"
git -C "$T" add featdir; git -C "$T" commit -qm feat
git -C "$T" checkout -q -    # 元ブランチへ戻る（main は featdir 未取り込み＝未マージ状態）
# P1) COMPLETE 未マージで produces パスが branch に実在 → OK(0)
jq -n '{tasks:{"task-020":{status:"COMPLETE",merged:false,branch:"worktree-task-020",produces:["featdir/Feature.kt"]}}}' > "$T/sprint/state.json"
expect "[produces] 未マージで成果物が branch に実在 → exit 0" 0 "$(run)"
# P2) COMPLETE 未マージで branch 実在だが produces パスがブランチに不在 → 警告(3)
jq -n '{tasks:{"task-021":{status:"COMPLETE",merged:false,branch:"worktree-task-020",produces:["featdir/Missing.kt"]}}}' > "$T/sprint/state.json"
expect "[produces] 宣言した成果物がブランチに不在 → exit 3" 3 "$(run)"
# P3) produces 未定義は後方互換（branch 実在で OK）
jq -n '{tasks:{"task-022":{status:"COMPLETE",merged:false,branch:"worktree-task-020"}}}' > "$T/sprint/state.json"
expect "[produces] produces 未定義は後方互換で exit 0" 0 "$(run)"
# P4) merged=true で produces パスが HEAD(root) に実在 → OK(0)
git -C "$T" merge --no-edit -q worktree-task-020 >/dev/null 2>&1
MERGED_HEAD=$(git -C "$T" rev-parse HEAD)
jq -n --arg c "$MERGED_HEAD" '{tasks:{"task-023":{status:"COMPLETE",merged:true,merge_commit:$c,produces:["featdir/Feature.kt"]}}}' > "$T/sprint/state.json"
expect "[produces] merged=true で成果物が HEAD に実在 → exit 0" 0 "$(run)"
# P5) merged=true だが produces パスが HEAD に不在 → 警告(3)
jq -n --arg c "$MERGED_HEAD" '{tasks:{"task-024":{status:"COMPLETE",merged:true,merge_commit:$c,produces:["featdir/Ghost.kt"]}}}' > "$T/sprint/state.json"
expect "[produces] merged=true で成果物が HEAD に不在 → exit 3" 3 "$(run)"

# --- FR-3: フック生存カナリア検査 ---
OLD_HB=$(date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2000-01-01T00:00:00Z")
NEW_HB=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2099-01-01T00:00:00Z")
# 8) RUNNING + heartbeat 古 → フック死亡の疑い → fail-closed(3)
jq -n --arg h "$OLD_HB" '{run_state:"RUNNING",hook_heartbeat:$h,tasks:{}}' > "$T/sprint/state.json"
expect "[FR-3] RUNNING + heartbeat 古 → fail-closed(3)" 3 "$(SPRINT_HEARTBEAT_MAX_AGE=60 run)"
# 9) RUNNING + heartbeat 新 → OK(0)
jq -n --arg h "$NEW_HB" '{run_state:"RUNNING",hook_heartbeat:$h,tasks:{}}' > "$T/sprint/state.json"
expect "[FR-3] RUNNING + heartbeat 新 → exit 0" 0 "$(SPRINT_HEARTBEAT_MAX_AGE=60 run)"
# 10) 終端（ABORTED/COMPLETE）は非アクティブ → heartbeat 古でも検査しない(0)
jq -n --arg h "$OLD_HB" '{run_state:"ABORTED",hook_heartbeat:$h,tasks:{}}' > "$T/sprint/state.json"
expect "[FR-3] ABORTED + heartbeat 古 → 検査せず exit 0" 0 "$(SPRINT_HEARTBEAT_MAX_AGE=60 run)"
jq -n --arg h "$OLD_HB" '{run_state:"COMPLETE",hook_heartbeat:$h,tasks:{}}' > "$T/sprint/state.json"
expect "[FR-3] COMPLETE + heartbeat 古 → 検査せず exit 0" 0 "$(SPRINT_HEARTBEAT_MAX_AGE=60 run)"
# 11) RUNNING で heartbeat 未記録 → フック未登録/無効化の疑い → fail-closed(3)
jq -n '{run_state:"RUNNING",tasks:{}}' > "$T/sprint/state.json"
expect "[FR-3] RUNNING + heartbeat 未記録 → fail-closed(3)" 3 "$(run)"

# 7) 前提不足: state.json 不在 → exit 0（no-op）
rm -f "$T/sprint/state.json"
expect "[前提不足] state.json 不在 → exit 0" 0 "$(run)"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
