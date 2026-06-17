#!/usr/bin/env bash
# .claude/sprint/hooks/persona-ambient.sh
# アンビエント人格注入フック（通常開発中のキャラ継続）。
#
# 目的:
#   直近スプリントで抽選されたオーケストレーター人格（キャラクター）の語り口を、
#   スプリント終了後・次スプリント開始前の「通常開発中」も継続して維持する。
#   ルート .claude/settings.json の SessionStart（startup|resume|compact）に登録され、
#   run_state=OFF の通常起動でも発火する。compact ソースを含めるのは、コンテキスト圧縮後に
#   ペルソナ定義（語尾・口癖）がコンテキストから消えてモデルが事前知識の典型語尾で補完し、
#   語尾が混線するのを防ぐため＝圧縮後にも語り口を再注入する。本フックは state を一切
#   変更しない装飾専用なので、compact で複数回発火しても冪等・安全（再注入は無害）。
#
# 設計上の安全性（規律隔離は保つ）:
#   - これは装飾（ユーザー対話の語り口）専用。state.json を一切変更せず、人格の抽選もしない
#     （既に state.json.persona がある場合だけ、その1ブロックを stdout に出すのみ）。
#   - スプリント実行中（RUNNING）は、スプリント本体の session-start.sh が
#     人格ブロックを注入するため、二重注入を避けて即 no-op する。
#   - 規律フック（PreToolUse ガード・Stop 等）は従来どおり sprint/settings.json に隔離され、
#     _guard.sh により通常開発では no-op のまま。本フックはそれらに一切影響しない。
#   - どんな失敗でもセッションを壊さない（常に exit 0）。jq/persona 未設定/SPRINT_PERSONA=off は no-op。
#
# 無効化:
#   SPRINT_PERSONA=off（0/false/no）で人格そのものを無効化（sprint_persona_block が空を返す）。
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$ROOT/sprint/state.json"

# state も jq も無ければ何もしない（クリーンな通常開発を妨げない）。
[ -f "$STATE_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# スプリント実行中はスプリント本体（session-start.sh）が人格を注入するので二重注入を避ける。
# 通常開発（OFF/COMPLETE/ABORTED）のときだけ継続注入を担う。
run_state=$(jq -r '.run_state // "OFF"' "$STATE_FILE" 2>/dev/null || echo "OFF")
case "$run_state" in
  RUNNING) exit 0 ;;
esac

# 既存 persona の語り口ブロックだけを出力（抽選はしない＝通常開発で勝手に人格を生やさない）。
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_persona.sh" 2>/dev/null || exit 0
command -v sprint_persona_block >/dev/null 2>&1 || exit 0

# 通常開発では V2 規律 (L1 フレームワークヘッダ) の注入が無く（バイト予算に余裕がある）、ここがキャラ継続体験の主舞台。
# rich で一人称/語尾/口癖/セリフ例まで出し、語り口を豊かに維持する。
block=$(ROOT="$ROOT" STATE_FILE="$STATE_FILE" sprint_persona_block rich 2>/dev/null || true)
[ -n "$block" ] && printf '%s\n' "$block"
exit 0
