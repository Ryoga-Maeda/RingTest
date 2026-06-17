#!/usr/bin/env bash
# scripts/verify-output-contract.sh — V2 output-contract 検査
#
# 目的:
#   サブエージェントの出力契約 yaml を読み、
#   required_artifacts / required_state_updates / forbidden_patterns を検査する。
#
# 引数:
#   $1 : contract yaml のパス（必須）
#
# 環境変数:
#   SPRINT_AGENT_OUTPUT : サブエージェントの最終出力テキストへのパス（任意）
#                         指定があり、ファイルが存在するとき forbidden_patterns を grep
#
# exit code:
#   0 = 検査 PASS
#   1 = 検査 FAIL（理由は stderr）
#
# 不変条件:
#   - 契約 yaml が無ければ exit 1
#   - yq が無い場合は forbidden_patterns のみ awk フォールバックで検査する
#   - required_artifacts / required_state_updates の検査は yq がある場合に限る
set -euo pipefail

CONTRACT="${1:-}"
if [ -z "$CONTRACT" ] || [ ! -f "$CONTRACT" ]; then
  echo "ERR: contract not found: $CONTRACT" >&2
  exit 1
fi

STATE=sprint/state.json
fail=0

# ------------------------------------------------------------
# forbidden_patterns 検査
# ------------------------------------------------------------
if [ -n "${SPRINT_AGENT_OUTPUT:-}" ] && [ -f "$SPRINT_AGENT_OUTPUT" ]; then
  # パターン抽出
  patterns_tmp=$(mktemp)
  if command -v yq >/dev/null 2>&1; then
    yq -r '.forbidden_patterns[]?' "$CONTRACT" > "$patterns_tmp" 2>/dev/null || true
  else
    # awk フォールバック: forbidden_patterns: 以下の "- xxx" 行を抜く
    awk '
      /^forbidden_patterns:/ { flag=1; next }
      /^[a-zA-Z]/             { flag=0 }
      flag && /^[[:space:]]*-/ {
        sub(/^[[:space:]]*-[[:space:]]*/, "")
        # 前後の "" を剥がす
        gsub(/^"/, ""); gsub(/"$/, "")
        gsub(/^'\''/, ""); gsub(/'\''$/, "")
        print
      }
    ' "$CONTRACT" > "$patterns_tmp"
  fi

  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if grep -qF -- "$pat" "$SPRINT_AGENT_OUTPUT"; then
      echo "FAIL: forbidden pattern detected: '$pat'" >&2
      fail=1
    fi
  done < "$patterns_tmp"
  rm -f "$patterns_tmp"
fi

# ------------------------------------------------------------
# required_artifacts / required_state_updates 検査（yq 必須）
# ------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  # required_artifacts
  ra_count=$(yq -r '.required_artifacts | length // 0' "$CONTRACT" 2>/dev/null || echo 0)
  ra_count=${ra_count:-0}
  if [ "$ra_count" != "null" ] && [ "$ra_count" -gt 0 ] 2>/dev/null; then
    for i in $(seq 0 $((ra_count - 1))); do
      path=$(yq -r ".required_artifacts[$i].path" "$CONTRACT")
      must_exist=$(yq -r ".required_artifacts[$i].must_exist // false" "$CONTRACT")
      must_not_empty=$(yq -r ".required_artifacts[$i].must_not_be_empty // false" "$CONTRACT")

      if [ "$must_exist" = "true" ] && [ ! -f "$path" ]; then
        echo "FAIL: required artifact missing: $path" >&2
        fail=1
      fi
      if [ "$must_not_empty" = "true" ] && [ -f "$path" ] && [ ! -s "$path" ]; then
        echo "FAIL: required artifact empty: $path" >&2
        fail=1
      fi

      # required_sections
      sec_count=$(yq -r ".required_artifacts[$i].schema.required_sections | length // 0" "$CONTRACT" 2>/dev/null || echo 0)
      sec_count=${sec_count:-0}
      if [ "$sec_count" != "null" ] && [ "$sec_count" -gt 0 ] 2>/dev/null; then
        for j in $(seq 0 $((sec_count - 1))); do
          sec=$(yq -r ".required_artifacts[$i].schema.required_sections[$j]" "$CONTRACT")
          if [ -f "$path" ] && ! grep -qF -- "$sec" "$path"; then
            echo "FAIL: required section missing in $path: '$sec'" >&2
            fail=1
          fi
        done
      fi
    done
  fi

  # required_state_updates
  if [ -f "$STATE" ]; then
    su_count=$(yq -r '.required_state_updates | length // 0' "$CONTRACT" 2>/dev/null || echo 0)
    su_count=${su_count:-0}
    if [ "$su_count" != "null" ] && [ "$su_count" -gt 0 ] 2>/dev/null; then
      for i in $(seq 0 $((su_count - 1))); do
        jq_path=$(yq -r ".required_state_updates[$i].jq_path" "$CONTRACT")
        must_equal=$(yq -r ".required_state_updates[$i].must_equal // \"__SKIP__\"" "$CONTRACT")
        must_type=$(yq -r ".required_state_updates[$i].must_be_type // \"__SKIP__\"" "$CONTRACT")

        actual=$(jq -r "$jq_path" "$STATE" 2>/dev/null || echo "__NULL__")
        if [ "$must_equal" != "__SKIP__" ] && [ "$actual" != "$must_equal" ]; then
          echo "FAIL: state update mismatch at $jq_path: got '$actual', want '$must_equal'" >&2
          fail=1
        fi
        if [ "$must_type" != "__SKIP__" ]; then
          typ=$(jq -r "$jq_path | type" "$STATE" 2>/dev/null || echo "null")
          if [ "$typ" != "$must_type" ]; then
            echo "FAIL: state type mismatch at $jq_path: got '$typ', want '$must_type'" >&2
            fail=1
          fi
        fi
      done
    fi
  fi
fi

exit "$fail"
