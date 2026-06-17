#!/usr/bin/env bash
# validate-agents-config.sh
#
# sprint/agents.config.json と sprint/agents.local.json（任意）を
# .claude/sprint/model-catalog.json と突き合わせて検証する。
#
# 検査項目:
#   - model: opus/sonnet/haiku/fable のいずれか
#   - effort: low/medium/high/xhigh/max のいずれか
#   - effort=max は policy.allow_max_effort_for に含まれる agent のみ許可
#   - model_versions の具体 ID は catalog.versions[] に存在すること
#   - catalog の各系列に latest フィールドが存在すること
#   - policy.warn_non_latest_version=true のとき、latest 以外は警告のみ
#
# エラー時は exit 1。警告のみなら stderr に出して exit 0。
set -euo pipefail

CONFIG="${CONFIG:-sprint/agents.config.json}"
LOCAL="${LOCAL:-sprint/agents.local.json}"
CATALOG="${CATALOG:-.claude/sprint/model-catalog.json}"

[ -f "$CONFIG" ]  || { echo "ERR: agents.config.json not found: $CONFIG" >&2; exit 1; }
[ -f "$CATALOG" ] || { echo "ERR: model-catalog.json not found: $CATALOG" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERR: jq not found" >&2; exit 1; }

VALID_MODELS=("opus" "sonnet" "haiku" "fable")
VALID_EFFORTS=("low" "medium" "high" "xhigh" "max")

fail=0
warn=0

in_array() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# ---- catalog の各系列に latest があるか --------------------------------------
for f in opus sonnet haiku fable; do
  latest=$(jq -r --arg f "$f" '.families[$f].latest // empty' "$CATALOG")
  if [ -z "$latest" ]; then
    echo "ERR: catalog.families.$f.latest が未設定" >&2
    fail=$((fail+1))
  fi
done

# ---- config 内の各 agent を検査 ---------------------------------------------
agent_names=$(jq -r '.agents | keys[]?' "$CONFIG")
for a in $agent_names; do
  # orchestrator は UI 側で決定するため検査対象外
  [ "$a" = "orchestrator" ] && continue

  # _note のみのエントリはスキップ
  note=$(jq -r --arg a "$a" '.agents[$a]._note // empty' "$CONFIG")
  has_model=$(jq -r --arg a "$a" '.agents[$a].model // empty' "$CONFIG")
  has_effort=$(jq -r --arg a "$a" '.agents[$a].effort // empty' "$CONFIG")
  if [ -n "$note" ] && [ -z "$has_model" ] && [ -z "$has_effort" ]; then
    continue
  fi

  model="$has_model"
  effort="$has_effort"

  # model enum
  if [ -n "$model" ] && ! in_array "$model" "${VALID_MODELS[@]}"; then
    echo "ERR: $a.model='$model' は (opus/sonnet/haiku/fable) のいずれでもない" >&2
    fail=$((fail+1))
  fi

  # effort enum
  if [ -n "$effort" ] && ! in_array "$effort" "${VALID_EFFORTS[@]}"; then
    echo "ERR: $a.effort='$effort' は (low/medium/high/xhigh/max) のいずれでもない" >&2
    fail=$((fail+1))
  fi

  # max effort の権限チェック
  if [ "$effort" = "max" ]; then
    allowed=$(jq -r --arg a "$a" \
      '[.policy.allow_max_effort_for[]?] | index($a) // empty' "$CONFIG")
    if [ -z "$allowed" ]; then
      echo "ERR: $a は effort=max だが policy.allow_max_effort_for に含まれていない" >&2
      fail=$((fail+1))
    fi
  fi
done

# ---- model_versions の具体 ID 検証 -----------------------------------------
warn_non_latest=$(jq -r '.policy.warn_non_latest_version // false' "$CONFIG")

for f in opus sonnet haiku fable; do
  raw=$(jq -r --arg f "$f" '.model_versions[$f] // "latest"' "$CONFIG")
  if [ "$raw" != "latest" ]; then
    exists=$(jq -r --arg f "$f" --arg id "$raw" \
      '.families[$f].versions[]? | select(.id == $id) | .id' "$CATALOG")
    if [ -z "$exists" ]; then
      echo "ERR: agents.config.json model_versions.$f='$raw' は catalog に存在しない" >&2
      fail=$((fail+1))
    fi
  fi
  if [ "$warn_non_latest" = "true" ]; then
    latest=$(jq -r --arg f "$f" '.families[$f].latest // empty' "$CATALOG")
    if [ "$raw" != "latest" ] && [ -n "$latest" ] && [ "$raw" != "$latest" ]; then
      echo "WARN: model_versions.$f='$raw' は latest ('$latest') ではない" >&2
      warn=$((warn+1))
    fi
  fi
done

# ---- local も検査（存在すれば model_versions のみ）-------------------------
if [ -f "$LOCAL" ]; then
  for f in opus sonnet haiku fable; do
    raw=$(jq -r --arg f "$f" '.model_versions[$f] // empty' "$LOCAL")
    [ -z "$raw" ] && continue
    [ "$raw" = "latest" ] && continue
    exists=$(jq -r --arg f "$f" --arg id "$raw" \
      '.families[$f].versions[]? | select(.id == $id) | .id' "$CATALOG")
    if [ -z "$exists" ]; then
      echo "ERR: agents.local.json model_versions.$f='$raw' は catalog に存在しない" >&2
      fail=$((fail+1))
    fi
  done

  # local 側の agent エントリも enum 検査
  local_agents=$(jq -r '.agents | keys[]?' "$LOCAL" 2>/dev/null || true)
  for a in $local_agents; do
    [ "$a" = "orchestrator" ] && continue
    lmodel=$(jq -r --arg a "$a" '.agents[$a].model // empty' "$LOCAL")
    leffort=$(jq -r --arg a "$a" '.agents[$a].effort // empty' "$LOCAL")
    if [ -n "$lmodel" ] && ! in_array "$lmodel" "${VALID_MODELS[@]}"; then
      echo "ERR: agents.local.json $a.model='$lmodel' は enum 外" >&2
      fail=$((fail+1))
    fi
    if [ -n "$leffort" ] && ! in_array "$leffort" "${VALID_EFFORTS[@]}"; then
      echo "ERR: agents.local.json $a.effort='$leffort' は enum 外" >&2
      fail=$((fail+1))
    fi
  done
fi

if [ "$fail" -gt 0 ]; then
  echo "Validation failed (errors=$fail warnings=$warn)" >&2
  exit 1
fi

if [ "$warn" -gt 0 ]; then
  echo "Validation passed with $warn warnings" >&2
fi
exit 0
