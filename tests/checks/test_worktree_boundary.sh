#!/usr/bin/env bash
# tests/checks/test_worktree_boundary.sh — R2 worktree_boundary.sh の単体テスト
# PT1-2: 一意帰属（FILE→worktree→IN_PROGRESS タスク）＋相互汚染検知（CWD が別 worktree なら deny）。
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT_REPO/.claude/sprint/policy/checks/worktree_boundary.sh"
PASS=0; FAIL=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sprint" "$T/.claude/sprint/policy/checks" \
  "$T/.claude/worktrees/task-01/src" "$T/.claude/worktrees/task-02/src" "$T/outside"
# PT1-1: 逆引きヘルパを sandbox に配置（R2 が source する）。
cp "$ROOT_REPO/.claude/sprint/policy/checks/_task_from_path.sh" "$T/.claude/sprint/policy/checks/"
export ROOT="$T" STATE_FILE="$T/sprint/state.json"

# run <file> [tool] [cwd]
run() { FILE="$1" TOOL="${2:-Write}" CWD="${3:-}" bash "$CHECK" >/dev/null 2>&1; echo $?; }
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected exit=$e got $a)"; FAIL=$((FAIL+1)); fi; }

state_inprogress() {
  cat > "$STATE_FILE" <<'EOF'
{"tasks":{"task-01":{"status":"IN_PROGRESS","worktree":".claude/worktrees/task-01"}}}
EOF
}
# 複数タスク同時 IN_PROGRESS（並列）
state_two_inprogress() {
  cat > "$STATE_FILE" <<'EOF'
{"tasks":{
  "task-01":{"status":"IN_PROGRESS","worktree":".claude/worktrees/task-01"},
  "task-02":{"status":"IN_PROGRESS","worktree":".claude/worktrees/task-02"}
}}
EOF
}
# task-02 は COMPLETE（残 worktree への書込は拒否されるべき）
state_one_inprogress_one_complete() {
  cat > "$STATE_FILE" <<'EOF'
{"tasks":{
  "task-01":{"status":"IN_PROGRESS","worktree":".claude/worktrees/task-01"},
  "task-02":{"status":"COMPLETE","worktree":".claude/worktrees/task-02"}
}}
EOF
}
state_integrate() {
  cat > "$STATE_FILE" <<'EOF'
{"phase":"INTEGRATE","tasks":{"task-01":{"status":"COMPLETE","worktree":".claude/worktrees/task-01"}}}
EOF
}

echo "=== test_worktree_boundary.sh (R2) ==="

# 正常: 担当 worktree 内（IN_PROGRESS）→ allow
state_inprogress
expect "[正常] worktree 内（IN_PROGRESS）→ allow" 0 "$(run "$T/.claude/worktrees/task-01/src/foo.ts")"

# 違反: worktree 外 → deny
state_inprogress
expect "[違反] worktree 外 → deny" 1 "$(run "$T/outside/foo.ts")"

# 例外: sprint/ 制御面 → allow（R5/R0 で別途保護）
state_inprogress
expect "[例外] sprint/state.json → allow" 0 "$(run "$T/sprint/state.json")"

# fail-closed: 進行中タスクなし＋worktree 外 → deny
echo '{"tasks":{}}' > "$STATE_FILE"
expect "[fail-closed] タスクなしで worktree 外編集 → deny" 1 "$(run "$T/outside/foo.ts")"

# 対象外: FILE 空 → allow
state_inprogress
expect "[対象外] FILE 空 → allow" 0 "$(run "")"

# 並列: 複数 IN_PROGRESS のとき、FILE が属する worktree が IN_PROGRESS なら allow
state_two_inprogress
expect "[並列] task-02 の worktree 内 → allow" 0 "$(run "$T/.claude/worktrees/task-02/src/bar.ts")"
expect "[並列] task-01 の worktree 内 → allow" 0 "$(run "$T/.claude/worktrees/task-01/src/foo.ts")"
expect "[並列] どの worktree 外 → deny" 1 "$(run "$T/outside/baz.ts")"

# PT1-2: 非 IN_PROGRESS タスクの worktree への書込 → deny（COMPLETE の残 worktree 汚染防止）
state_one_inprogress_one_complete
expect "[PT1-2] COMPLETE タスクの worktree への書込 → deny" 1 "$(run "$T/.claude/worktrees/task-02/src/bar.ts")"
expect "[PT1-2] IN_PROGRESS タスクの worktree は allow" 0 "$(run "$T/.claude/worktrees/task-01/src/foo.ts")"

# PT1-2: 相互汚染検知 — CWD が別 worktree のタスクなら deny
state_two_inprogress
expect "[PT1-2] 相互汚染: CWD=task-01 から task-02 worktree へ書込 → deny" 1 \
  "$(run "$T/.claude/worktrees/task-02/src/bar.ts" Write "$T/.claude/worktrees/task-01")"
expect "[PT1-2] 自分の worktree（CWD=task-01, FILE=task-01）→ allow" 0 \
  "$(run "$T/.claude/worktrees/task-01/src/foo.ts" Write "$T/.claude/worktrees/task-01")"
expect "[PT1-2] CWD が root（worktree 外）なら越境判定スキップ→ allow" 0 \
  "$(run "$T/.claude/worktrees/task-02/src/bar.ts" Write "$T")"

# 2-3: INTEGRATE フェーズは統合作業窓 → root 直下の編集を allow
state_integrate
expect "[2-3] INTEGRATE で root 直下編集 → allow" 0 "$(run "$T/outside/ci-fix.yml")"
expect "[2-3] INTEGRATE で worktree 内編集 → allow" 0 "$(run "$T/.claude/worktrees/task-01/src/foo.ts")"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
