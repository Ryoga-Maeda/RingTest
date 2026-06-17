#!/usr/bin/env bash
# scripts/resilience.sh
# 「スプリント間の軽微な修正」でもストール自動回復（生成停滞の watchdog/リトライ）を
# 使えるようにするオプトイントグル。サブコマンド on / off / status を持つ。
#
# 設計（隔離維持の不変条件）:
#   ストール回復の実体は Claude Code が起動時に読む env（CLAUDE_ENABLE_STREAM_WATCHDOG /
#   API_TIMEOUT_MS / CLAUDE_CODE_MAX_RETRIES）である。本スクリプトはこれを
#   .claude/settings.local.json（gitignored・Claude Code が自動ロードする local override）の
#   .env へ「だけ」注入する。hooks/statusLine は一切注入しない＝規律ゲート（R0–R5・RULES 注入）は
#   絶対に有効化しない（test_isolation.sh の隔離不変条件を壊さない）。Web/クラウドでも効く正攻法。
#   既存ファイルのマージ/除去/fail-safe 作法は cloud-kickoff.sh / sprint-deactivate.sh と対称。
#
# 重要（スプリント機能との同一キー）:
#   ここで扱う3キーは .claude/sprint/settings.json の .env と「同一キー」であり、スプリント運用と
#   併用すると相互に影響し得る。cloud-kickoff がスプリント起動時に同キーを settings.local.json へ
#   注入し、sprint-deactivate がスプリント終了時に撤去する。そのため本スクリプトは、スプリント稼働の
#   代理判定（settings.local.json に .hooks があるか）で off をスキップし、on/status で警告/注記を出す。
#   スプリント外での利用を推奨する。
set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOCAL="$ROOT/.claude/settings.local.json"

# ストール回復 env のキー名一覧（ドリフト防止のため1か所に定義し on/off/status で共用）。
RESILIENCE_KEYS=(CLAUDE_ENABLE_STREAM_WATCHDOG API_TIMEOUT_MS CLAUDE_CODE_MAX_RETRIES)

# スプリント稼働の代理判定: settings.local.json に .hooks があればスプリント稼働中
# （cloud-kickoff が注入）とみなす。state.json/hooks の実体を見ずに安全側へ倒すための軽量ヒューリスティック。
is_sprint_active() { [ -f "$LOCAL" ] && jq -e '.hooks' "$LOCAL" >/dev/null 2>&1; }

usage() {
  cat >&2 <<'EOF'
使い方: bash scripts/resilience.sh <on|off|status>
  on      ストール自動回復 env を .claude/settings.local.json に注入（オプトイン有効化）
  off     注入した env のみ除去（他キーは保持）。env が空ならファイルを削除
  status  現在の有効/無効と各キーの値を表示（読み取り専用）
  ※各サブコマンドは余分な引数を受け付けません（例: on off は不可）。

env で注入値を上書き可能（既定）:
  CLAUDE_ENABLE_STREAM_WATCHDOG（既定 1）
  API_TIMEOUT_MS（既定 300000）
  CLAUDE_CODE_MAX_RETRIES（既定 10）
例: API_TIMEOUT_MS=120000 bash scripts/resilience.sh on
EOF
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "エラー: jq が必要です（settings.local.json の JSON 操作に使用）。インストールしてください。" >&2
    exit 1
  fi
}

# 実行時 env を尊重したストール回復プロファイル（JSON オブジェクト）を組み立てる。
build_profile_json() {
  jq -n \
    --arg watchdog "${CLAUDE_ENABLE_STREAM_WATCHDOG:-1}" \
    --arg timeout  "${API_TIMEOUT_MS:-300000}" \
    --arg retries  "${CLAUDE_CODE_MAX_RETRIES:-10}" \
    '{CLAUDE_ENABLE_STREAM_WATCHDOG: $watchdog, API_TIMEOUT_MS: $timeout, CLAUDE_CODE_MAX_RETRIES: $retries}'
}

cmd_on() {
  require_jq

  # スプリント稼働中（hooks 検出）の警告: 同3キーはスプリント機能も管理しており、
  # スプリント終了時の sprint-deactivate で撤去され得る（override 値も含む）。
  # 値は同一なので注入自体は無害なため、注入は行いつつ周知する。
  if is_sprint_active; then
    echo "警告: スプリント稼働中（hooks 検出）。これら3キーはスプリント機能も管理しており、" >&2
    echo "      スプリント終了時の sprint-deactivate で撤去され得ます（override 値も含む）。" >&2
    echo "      スプリント外での利用を推奨します。" >&2
  fi

  local profile existing
  profile="$(build_profile_json)"

  # 既存を読む（無ければ {}）。壊れた JSON のときは上書きせず警告して exit 1（fail-safe）。
  existing="{}"
  if [ -f "$LOCAL" ]; then
    if ! jq -e . "$LOCAL" >/dev/null 2>&1; then
      echo "警告: $LOCAL が壊れた JSON のため上書きしません（fail-safe）。手動で修正してください。" >&2
      exit 1
    fi
    existing="$(cat "$LOCAL")"
  fi

  mkdir -p "$ROOT/.claude"
  # .env にのみマージ注入。.hooks/.statusLine は絶対に設定しない（隔離維持）。tmp+mv で原子的に書く。
  if printf '%s' "$existing" | jq --argjson p "$profile" '.env = ((.env // {}) + $p)' \
       > "$LOCAL.tmp" 2>/dev/null; then
    mv "$LOCAL.tmp" "$LOCAL"
  else
    rm -f "$LOCAL.tmp"
    echo "警告: $LOCAL への env 注入に失敗（既存ファイルは保持）。" >&2
    exit 1
  fi

  echo "ストール自動回復を有効化しました（env のみ・hooks 注入なし＝隔離維持）: $LOCAL" >&2
  local k
  for k in "${RESILIENCE_KEYS[@]}"; do
    printf '  %s = %s\n' "$k" "$(jq -r --arg k "$k" '.env[$k] // ""' "$LOCAL")" >&2
  done
  echo "ヒント: Web/クラウドで再 clone を跨いで常用したい場合は、環境（Environment）の env 設定に" >&2
  echo "       同じ変数（${RESILIENCE_KEYS[*]}）を入れると永続化します。" >&2
}

cmd_off() {
  require_jq

  # スプリント稼働中（hooks 検出）は env を一切変更せずスキップ（シナリオB対策）。
  # スプリントが注入した同3キーを誤って削除しないため、安全側へ倒す。
  if is_sprint_active; then
    echo "スプリント稼働中（hooks 検出）のため off をスキップしました。" >&2
    echo "スプリントの env はスプリント側（sprint-deactivate）で管理されます。" >&2
    echo "スプリント終了後に再度 off してください。" >&2
    exit 0
  fi

  # ファイルが無ければ何もせず exit 0。
  [ -f "$LOCAL" ] || exit 0
  # 壊れた JSON は触らず警告（fail-safe）。
  if ! jq -e . "$LOCAL" >/dev/null 2>&1; then
    echo "警告: $LOCAL が壊れた JSON のため触りません（fail-safe）。" >&2
    exit 0
  fi

  # RESILIENCE_KEYS を JSON 配列にして渡す（ドリフト防止）。
  local keys_json
  keys_json="$(printf '%s\n' "${RESILIENCE_KEYS[@]}" | jq -R . | jq -s .)"

  # RESILIENCE_KEYS だけを .env から除去（他の env キー＝ユーザー独自やスプリント由来は保持）。
  # .env が空になれば del(.env)。.hooks は絶対に触らない（稼働中スプリントを壊さない）。
  if jq --argjson ek "$keys_json" \
       '(if (.env != null)
         then .env = (.env | with_entries(select(.key as $k | ($ek | index($k)) | not)))
         else . end)
        | (if (.env // {}) == {} then del(.env) else . end)' \
       "$LOCAL" > "$LOCAL.tmp" 2>/dev/null; then
    # オブジェクト全体が空になればファイルごと削除（sprint-deactivate と対称）。
    if [ "$(jq '(keys | length)' "$LOCAL.tmp" 2>/dev/null || echo 1)" = "0" ]; then
      rm -f "$LOCAL" "$LOCAL.tmp"
      echo "ストール自動回復を解除し、空の $LOCAL を削除しました。" >&2
    else
      mv "$LOCAL.tmp" "$LOCAL"
      echo "ストール自動回復 env を解除しました（他キーは保持）: $LOCAL" >&2
    fi
  else
    rm -f "$LOCAL.tmp"
    echo "警告: $LOCAL の更新に失敗（既存ファイルは保持）。" >&2
    exit 1
  fi
}

cmd_status() {
  require_jq
  local has_local="no"
  [ -f "$LOCAL" ] && jq -e . "$LOCAL" >/dev/null 2>&1 && has_local="yes"

  # いずれかのキーが .env にあれば「有効」とみなす。
  local any="no" k val
  if [ "$has_local" = "yes" ]; then
    for k in "${RESILIENCE_KEYS[@]}"; do
      if jq -e --arg k "$k" '.env[$k]' "$LOCAL" >/dev/null 2>&1; then any="yes"; fi
    done
  fi

  # スプリント稼働中（hooks 検出）なら、表示値が sprint 由来かもしれない旨を注記する。
  local note=""
  if is_sprint_active; then
    note="（スプリント稼働中: 表示中の値は sprint 由来の可能性あり）"
  fi

  if [ "$any" = "yes" ]; then
    echo "ストール自動回復: 有効（$LOCAL）${note}"
    for k in "${RESILIENCE_KEYS[@]}"; do
      val="$(jq -r --arg k "$k" '.env[$k] // "（未設定）"' "$LOCAL" 2>/dev/null || echo "（未設定）")"
      printf '  %s = %s\n' "$k" "$val"
    done
  else
    echo "ストール自動回復: 無効（settings.local.json に env なし）${note}"
    for k in "${RESILIENCE_KEYS[@]}"; do
      printf '  %s = （未設定）\n' "$k"
    done
  fi
}

main() {
  local sub="${1:-}"
  case "$sub" in
    on|off|status)
      # 余分な引数（例: resilience.sh on off）を黙って無視しない。usage 表示＋exit 2。
      if [ "$#" -ne 1 ]; then
        echo "エラー: '$sub' は引数を取りません（余分な引数: ${*:2}）。" >&2
        usage
        exit 2
      fi
      ;;
  esac
  case "$sub" in
    on)     cmd_on ;;
    off)    cmd_off ;;
    status) cmd_status ;;
    *)      usage; exit 2 ;;
  esac
}

main "$@"
