#!/usr/bin/env bash
# T-D.13: build-agent-prompts.sh
# L1 (framework header) + L2 (layer common) + L3 (per-agent body) を結合して
# .claude/agents/_build/<layer>/<name>.md に書き出す。
# frontmatter は L3 のものを保持する。冪等。
set -euo pipefail

ROOT="${SPRINT_ROOT:-.}"
PREFIX="$ROOT/.claude/agents/_prefix"
BUILD="$ROOT/.claude/agents/_build"

L1="$PREFIX/L1-framework-header.md"
[ -f "$L1" ] || { echo "ERR: $L1 not found" >&2; exit 1; }

L1_BODY=$(cat "$L1")

# レイヤー → L2 ファイル
declare -A L2_MAP=(
  ["phase"]="$PREFIX/L2-process-lead.md"
  ["execution"]="$PREFIX/L2-execution.md"
  ["infra"]="$PREFIX/L2-infra.md"
)

# frontmatter (---\n...\n---) と本文を分離
# 出力: ${2}.fm に frontmatter、${2}.body に本文
split_frontmatter() {
  local f="$1"
  local prefix="$2"
  : > "${prefix}.fm"
  : > "${prefix}.body"
  awk -v out_fm="${prefix}.fm" -v out_body="${prefix}.body" '
    BEGIN { state=0 }
    {
      if (state==0 && $0=="---") { state=1; print >> out_fm; next }
      if (state==1) {
        print >> out_fm
        if ($0=="---") { state=2; next }
        next
      }
      if (state==0) { state=2 }
      print >> out_body
    }
  ' "$f"
}

build_one() {
  local layer="$1" name="$2" src="$3"
  local l2_path="${L2_MAP[$layer]:-}"
  local outdir="$BUILD/$layer"
  mkdir -p "$outdir"
  local outfile="$outdir/$name"

  local tmp; tmp=$(mktemp -d)
  split_frontmatter "$src" "$tmp/x"
  local fm body
  fm=$(cat "$tmp/x.fm" 2>/dev/null || true)
  body=$(cat "$tmp/x.body" 2>/dev/null || true)

  local l2_body=""
  if [ -n "$l2_path" ] && [ -f "$l2_path" ]; then
    l2_body=$(cat "$l2_path")
  fi

  local combined
  if [ -n "$fm" ]; then
    if [ -n "$l2_body" ]; then
      combined="${fm}

${L1_BODY}

---

${l2_body}

---

${body}"
    else
      combined="${fm}

${L1_BODY}

---

${body}"
    fi
  else
    if [ -n "$l2_body" ]; then
      combined="${L1_BODY}

---

${l2_body}

---

${body}"
    else
      combined="${L1_BODY}

---

${body}"
    fi
  fi

  # 冪等: 既存と完全一致したらスキップ
  local new_sha
  new_sha=$(printf '%s\n' "$combined" | sha256sum | cut -d' ' -f1)
  if [ -f "$outfile" ]; then
    local cur_sha
    cur_sha=$(sha256sum "$outfile" | cut -d' ' -f1)
    if [ "$new_sha" = "$cur_sha" ]; then
      rm -rf "$tmp"
      return 0
    fi
  fi
  printf '%s\n' "$combined" > "$outfile"
  rm -rf "$tmp"
}

# 各レイヤーを処理
for layer in phase execution infra; do
  src_dir="$ROOT/.claude/agents/$layer"
  [ -d "$src_dir" ] || continue
  for f in "$src_dir"/*.md; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    build_one "$layer" "$name" "$f"
  done
done

# orchestrator-v2.md は L1+L2 を持たない（薄殻シェル）
ORCH="$ROOT/.claude/agents/orchestrator-v2.md"
if [ -f "$ORCH" ]; then
  mkdir -p "$BUILD"
  if ! cmp -s "$ORCH" "$BUILD/orchestrator-v2.md" 2>/dev/null; then
    cp "$ORCH" "$BUILD/orchestrator-v2.md"
  fi
fi

echo "build-agent-prompts: done"
