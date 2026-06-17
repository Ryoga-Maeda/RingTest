#!/usr/bin/env bash
# V2 人格初期化 (§3.1 行 172 の責務担当)
#
# 責務:
#   state.json.persona が未設定なら personas.json から1体抽選し、丸ごと永続化する。
#   v2_active=true のときだけ実体作業を行い、v1 only state には作用しない。
#
# 設計判断:
#   抽選・永続化・制御面 commit (IH-W6) のロジックは `.claude/sprint/hooks/_persona.sh` の
#   `sprint_roll_persona` に集約済み。本スクリプトは「V2 経路の起動点」を担う薄殻ラッパに
#   徹し、env 無効化 (SPRINT_PERSONA=off) ／atomic 更新 (`update_state`) ／再 clone 跨ぎ
#   維持 (`sprint_control_plane_commit`) ／旧スキーマ互換を `_persona.sh` 側から自動継承する。
#
# 不変条件:
#   - 冪等。persona 設定済みなら何もしない。
#   - 失敗してもセッションを壊さない (best-effort)。
#   - SessionStart フックから cwd=リポジトリルートで呼ばれる前提だが、CLAUDE_PROJECT_DIR を
#     優先することで他コンテキストからの呼出にも防御的に対応する。
set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATE_FILE="$ROOT/sprint/state.json"
[ -f "$STATE_FILE" ] || exit 0

# v2_active != true のときは何もしない (v1 並走のため)。
[ "$(jq -r '.v2_active // false' "$STATE_FILE" 2>/dev/null || echo false)" = "true" ] || exit 0

export ROOT STATE_FILE
# shellcheck disable=SC1090
source "$ROOT/.claude/sprint/hooks/_persona.sh" 2>/dev/null || exit 0

command -v sprint_roll_persona >/dev/null 2>&1 || exit 0
sprint_roll_persona || true
