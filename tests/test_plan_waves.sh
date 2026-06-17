#!/usr/bin/env bash
# tests/test_plan_waves.sh — PT2-3: DAG ウェーブ計画（柱1・B5）
set -uo pipefail
ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_REPO/scripts/plan-waves.sh"
PASS=0; FAIL=0
expect() { local d="$1" e="$2" a="$3"; if [ "$a" = "$e" ]; then echo "  PASS: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected=$e got=$a)"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sprint" "$T/scripts"
cp "$SCRIPT" "$T/scripts/"
RUN() { CLAUDE_PROJECT_DIR="$T" bash "$T/scripts/plan-waves.sh"; }
setstate() { printf '%s\n' "$1" > "$T/sprint/state.json"; }

echo "=== test_plan_waves.sh (PT2-3) ==="

# (1) 独立3タスク（依存なし・touches 非重複）→ 全部 wave 0
setstate '{"tasks":{
  "task-001":{"depends_on":[],"touches":["src/a"]},
  "task-002":{"depends_on":[],"touches":["src/b"]},
  "task-003":{"depends_on":[],"touches":["src/c"]}
}}'
OUT=$(RUN)
expect "[独立] ウェーブ数=1" "1" "$(echo "$OUT" | jq '.waves | length')"
expect "[独立] wave0 に3タスク" "3" "$(echo "$OUT" | jq '.waves[0] | length')"

# (2) 依存あり: task-004 が task-001,task-002 に依存 → wave1 へ
setstate '{"tasks":{
  "task-001":{"depends_on":[],"touches":["src/a"]},
  "task-002":{"depends_on":[],"touches":["src/b"]},
  "task-004":{"depends_on":["task-001","task-002"],"touches":["src/d"]}
}}'
OUT=$(RUN)
expect "[依存] ウェーブ数=2" "2" "$(echo "$OUT" | jq '.waves | length')"
expect "[依存] wave0 は task-001,task-002" "task-001 task-002" "$(echo "$OUT" | jq -r '.waves[0] | join(" ")')"
expect "[依存] wave1 は task-004" "task-004" "$(echo "$OUT" | jq -r '.waves[1] | join(" ")')"

# (3) ファイル重なり: 同レベルの task-001,task-002 が同じファイルを触る → 別ウェーブへ直列化
setstate '{"tasks":{
  "task-001":{"depends_on":[],"touches":["src/shared.ts"]},
  "task-002":{"depends_on":[],"touches":["src/shared.ts"]}
}}'
OUT=$(RUN)
expect "[重なり] 同ファイルは別ウェーブ（数=2）" "2" "$(echo "$OUT" | jq '.waves | length')"
expect "[重なり] 各ウェーブ1タスク" "1" "$(echo "$OUT" | jq '.waves[0] | length')"

# (3b) プレフィックス重なり: dir と dir/file は重なる扱い
setstate '{"tasks":{
  "task-001":{"depends_on":[],"touches":["app/"]},
  "task-002":{"depends_on":[],"touches":["app/Main.kt"]}
}}'
expect "[重なり] プレフィックス（app/ と app/Main.kt）は直列化" "2" "$(RUN | jq '.waves | length')"

# (4) COMPLETE 依存は満たされたとみなす（再開時の計画）
setstate '{"tasks":{
  "task-001":{"status":"COMPLETE","depends_on":[],"touches":["src/a"]},
  "task-002":{"depends_on":["task-001"],"touches":["src/b"]}
}}'
OUT=$(RUN)
expect "[再開] COMPLETE は計画から除外" "1" "$(echo "$OUT" | jq '.waves | length')"
expect "[再開] 残りは task-002 のみ wave0" "task-002" "$(echo "$OUT" | jq -r '.waves[0] | join(" ")')"

# (5) 循環依存 → 非ゼロ終了
setstate '{"tasks":{
  "task-001":{"depends_on":["task-002"]},
  "task-002":{"depends_on":["task-001"]}
}}'
if RUN >/dev/null 2>&1; then expect "[循環] 循環依存は非ゼロ終了" "nonzero" "zero"; else expect "[循環] 循環依存は非ゼロ終了" "nonzero" "nonzero"; fi

# (6) タスクなし → 空ウェーブ
setstate '{"tasks":{}}'
expect "[空] タスクなしは waves=[]" "0" "$(RUN | jq '.waves | length')"

# (7) 3段の連鎖: 001 → 002 → 003
setstate '{"tasks":{
  "task-001":{"depends_on":[],"touches":["a"]},
  "task-002":{"depends_on":["task-001"],"touches":["b"]},
  "task-003":{"depends_on":["task-002"],"touches":["c"]}
}}'
expect "[連鎖] 3段でウェーブ数=3" "3" "$(RUN | jq '.waves | length')"

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
