#!/usr/bin/env bash
# agents-config-merge.sh
#
# 3 層マージ（frontmatter < agents.config.json < agents.local.json）+
# model_versions 解決を行い、sprint/.agents.merged.json を書き出す。
#
# - frontmatter は .claude/agents/_build/**/*.md の YAML ヘッダを採取
# - agents.config.json で上書き
# - agents.local.json（存在すれば）でさらに上書き
# - model_versions は "latest" を catalog.families.<f>.latest で解決
#
# 依存: jq, python3
set -euo pipefail

CATALOG="${CATALOG:-.claude/sprint/model-catalog.json}"
CONFIG="${CONFIG:-sprint/agents.config.json}"
LOCAL="${LOCAL:-sprint/agents.local.json}"
BUILD_DIR="${BUILD_DIR:-.claude/agents/_build}"
OUT="${OUT:-sprint/.agents.merged.json}"

[ -f "$CATALOG" ] || { echo "ERR: model-catalog.json not found: $CATALOG" >&2; exit 1; }
[ -f "$CONFIG" ]  || { echo "ERR: agents.config.json not found: $CONFIG" >&2; exit 1; }

command -v jq      >/dev/null 2>&1 || { echo "ERR: jq not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERR: python3 not found" >&2; exit 1; }

# ---- Step 1: defaults を取得 -------------------------------------------------
default_model=$(jq -r '.defaults.model // "sonnet"' "$CONFIG")
default_effort=$(jq -r '.defaults.effort // "high"' "$CONFIG")

# ---- Step 2: config + local を deep-merge ------------------------------------
# jq の `*` は再帰的にマージし、local 側が優先される。
if [ -f "$LOCAL" ]; then
  merged=$(jq -s '.[0] * .[1]' "$CONFIG" "$LOCAL")
else
  merged=$(jq '.' "$CONFIG")
fi

# ---- Step 3: model_versions の解決 ------------------------------------------
resolve_version() {
  local family="$1" raw="$2"
  if [ "$raw" = "latest" ] || [ -z "$raw" ]; then
    jq -r --arg f "$family" '.families[$f].latest // empty' "$CATALOG"
  else
    local exists
    exists=$(jq -r --arg f "$family" --arg id "$raw" \
      '.families[$f].versions[]? | select(.id == $id) | .id' "$CATALOG")
    if [ -n "$exists" ]; then
      echo "$exists"
    else
      # catalog に無い ID。空文字を返して呼び出し側で検出させる。
      echo ""
    fi
  fi
}

mv_opus=$(echo "$merged"  | jq -r '.model_versions.opus   // "latest"')
mv_sonnet=$(echo "$merged"| jq -r '.model_versions.sonnet // "latest"')
mv_haiku=$(echo "$merged" | jq -r '.model_versions.haiku  // "latest"')
mv_fable=$(echo "$merged" | jq -r '.model_versions.fable  // "latest"')

opus_id=$(resolve_version opus   "$mv_opus")
sonnet_id=$(resolve_version sonnet "$mv_sonnet")
haiku_id=$(resolve_version haiku  "$mv_haiku")
fable_id=$(resolve_version fable  "$mv_fable")

for pair in "opus:$opus_id" "sonnet:$sonnet_id" "haiku:$haiku_id" "fable:$fable_id"; do
  fam="${pair%%:*}"
  rid="${pair#*:}"
  if [ -z "$rid" ]; then
    echo "ERR: model_versions.$fam を catalog で解決できませんでした" >&2
    exit 1
  fi
done

# ---- Step 4: frontmatter から agent ごとのデフォルト model/effort を抽出 -----
# 結果は {"<name>": {"model": "...", "effort": "..."}, ...} 形式の JSON。
# frontmatter に model/effort が無ければ {} を入れる。
frontmatter_json='{}'
if [ -d "$BUILD_DIR" ]; then
  frontmatter_json=$(python3 - "$BUILD_DIR" <<'PY'
import json, os, re, sys

build_dir = sys.argv[1]
out = {}

# シンプルな YAML frontmatter パーサ。
# ファイル先頭が '---' で始まる場合のみ採取し、key: value の単純行のみ取り出す。
KEYS = ("model", "effort")

def parse_frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.+?)\s*$', line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        # クォート剥がし
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        if k in KEYS:
            fm[k] = v
    return fm

for root, _dirs, files in os.walk(build_dir):
    for fn in files:
        if not fn.endswith(".md"):
            continue
        name = os.path.splitext(fn)[0]
        try:
            with open(os.path.join(root, fn), encoding="utf-8") as f:
                text = f.read()
        except OSError:
            continue
        fm = parse_frontmatter(text)
        if fm:
            out[name] = fm

print(json.dumps(out, ensure_ascii=False))
PY
)
fi

# ---- Step 5: agent ごとに 3 層マージし、model_id を解決 ---------------------
agents_cfg=$(echo "$merged" | jq -c '.agents // {}')

result=$(
  AGENTS_CFG="$agents_cfg" \
  FRONTMATTER="$frontmatter_json" \
  DEFAULT_MODEL="$default_model" \
  DEFAULT_EFFORT="$default_effort" \
  OPUS_ID="$opus_id" \
  SONNET_ID="$sonnet_id" \
  HAIKU_ID="$haiku_id" \
  FABLE_ID="$fable_id" \
  python3 - <<'PY'
import json, os

agents_cfg  = json.loads(os.environ["AGENTS_CFG"])
frontmatter = json.loads(os.environ["FRONTMATTER"])
default_model  = os.environ.get("DEFAULT_MODEL",  "sonnet")
default_effort = os.environ.get("DEFAULT_EFFORT", "high")
id_map = {
    "opus":   os.environ.get("OPUS_ID",   ""),
    "sonnet": os.environ.get("SONNET_ID", ""),
    "haiku":  os.environ.get("HAIKU_ID",  ""),
    "fable":  os.environ.get("FABLE_ID",  ""),
}

# frontmatter に存在する agent も対象に含める（config 未掲載でも採取）
names = set(agents_cfg.keys()) | set(frontmatter.keys())
out = {}
for name in sorted(names):
    cfg = agents_cfg.get(name, {})
    if not isinstance(cfg, dict):
        cfg = {}
    # orchestrator のような _note 付きエントリはスキップ
    if "_note" in cfg and not (cfg.get("model") or cfg.get("effort")):
        continue
    fm = frontmatter.get(name, {}) if isinstance(frontmatter.get(name), dict) else {}

    # 3 層マージ: defaults < frontmatter < config(=local 反映済み)
    model  = cfg.get("model")  or fm.get("model")  or default_model
    effort = cfg.get("effort") or fm.get("effort") or default_effort

    model_id = id_map.get(model, "")
    out[name] = {
        "model_family": model,
        "model_id": model_id,
        "effort": effort,
    }

print(json.dumps(out, ensure_ascii=False))
PY
)

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$OUT")"
jq -n \
  --arg ts "$ts" \
  --arg op "$opus_id" \
  --arg so "$sonnet_id" \
  --arg ha "$haiku_id" \
  --arg fa "$fable_id" \
  --argjson ag "$result" '
{
  merged_at: $ts,
  model_versions_resolved: {
    opus:   $op,
    sonnet: $so,
    haiku:  $ha,
    fable:  $fa
  },
  agents: $ag
}' > "$OUT"

echo "merged: $OUT"
