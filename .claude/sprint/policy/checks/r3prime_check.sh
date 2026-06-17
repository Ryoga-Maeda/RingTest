#!/usr/bin/env bash
# R3' 強制チェック: 改善フェーズ（sub_phase=improve）の I-* タスクは、
# 最初の commit がテストファイルのみで構成されている必要がある。
# pre-commit フックからチェーン呼出される想定。
set -euo pipefail

STATE=sprint/state.json
[ -f "$STATE" ] || exit 0

# v2_active=true かつ sub_phase=improve のときのみ作動
v2=$(jq -r '.v2_active // false' "$STATE" 2>/dev/null || echo "false")
sub=$(jq -r '.sub_phase // "implement"' "$STATE" 2>/dev/null || echo "implement")

if [ "$v2" != "true" ] || [ "$sub" != "improve" ]; then
  # 改善フェーズ以外は素通し
  exit 0
fi

# タスク ID を branch 名から推定（例: improve/<sprint>/I-NNN）
# 空リポジトリ（commit 未作成）でも検出できるよう symbolic-ref を優先する
branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
task_id=$(echo "$branch" | grep -oE 'I-[0-9]+' | head -1 || true)

if [ -z "$task_id" ]; then
  # I-* タスクでなければ素通し
  exit 0
fi

status_file="sprint/tasks/${task_id}.status.json"
if [ ! -f "$status_file" ]; then
  # status ファイルが無ければ新規作成（{} で初期化）
  mkdir -p "$(dirname "$status_file")"
  echo '{}' > "$status_file"
fi

first_sha=$(jq -r '.r3prime_first_commit_sha // ""' "$status_file" 2>/dev/null || echo "")

# 最初のコミットが既に記録されていれば後続コミット扱い → 検査済みとして通過
if [ -n "$first_sha" ]; then
  exit 0
fi

# これから commit される変更ファイル一覧（cached diff）
changed=$(git diff --cached --name-only 2>/dev/null || echo "")

# テストファイル判定
is_test() {
  local f="$1"
  case "$f" in
    test_*.sh|*_test.sh) return 0 ;;
    *_test.py|*.test.py) return 0 ;;
    *.spec.ts|*.spec.js) return 0 ;;
    *.test.ts|*.test.js) return 0 ;;
    tests/*|*/tests/*) return 0 ;;
    *__tests__/*|*/__tests__/*) return 0 ;;
    *) return 1 ;;
  esac
}

non_test_files=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # sprint/ 制御面の付随ファイル（status.json など）は許容
  case "$f" in
    sprint/*) continue ;;
  esac
  if ! is_test "$f"; then
    non_test_files="${non_test_files}${f}\n"
  fi
done <<< "$changed"

if [ -n "$non_test_files" ]; then
  echo "R3' 違反: 改善フェーズ ($task_id) の最初の commit は test ファイルのみで構成する必要があります" >&2
  echo "非テストファイル:" >&2
  printf '%b' "$non_test_files" >&2
  exit 1
fi

# pre-commit 段階では SHA を確定できないため、ブロックのみ実施。
# 記録（r3prime_first_commit_sha）は post-commit 側に委ねる。
exit 0
