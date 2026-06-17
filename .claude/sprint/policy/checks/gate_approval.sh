#!/usr/bin/env bash
# R5: Human ゲート承認チェック
#   (a) 承認記録ファイル gate_approvals.json への Write/Edit を常時 deny（自己承認防止）
#   (b) state.json への書き込み時、CLARIFY フェーズで「.phase を CLARIFY 以外へ変更」
#       しようとしており、かつ Human 承認が無い場合のみ deny。
#       （resume_hint 等、phase を変えない通常更新は CLARIFY 中でも許可する）
#   (c) 承認済みでも、承認時点の PRODUCT.md ハッシュと現在の PRODUCT.md が一致しない場合は
#       「承認後に仕様が書き換えられた」とみなして deny（再承認を要求）。TOCTOU 対策。
# exit 0 = 許可 / exit 1 = 拒否（拒否理由を標準出力）/ 判定不能 = exit 1（fail-closed）
#
# 入力（環境変数）: FILE, STATE_FILE, ROOT, TOOL / 引数 $1=ツール呼び出し JSON

[ -z "${FILE:-}" ] && exit 0

ROOT="${ROOT:-.}"
APPROVALS_FILE="${ROOT}/sprint/gate_approvals.json"
PRODUCT_FILE="${ROOT}/sprint/PRODUCT.md"

# パスを正規化して厳密一致で判定する（部分一致による誤検出/誤回避を避ける）。
FILE_REAL=$(realpath -m "$FILE" 2>/dev/null || echo "$FILE")
ROOT_REAL=$(realpath -m "$ROOT" 2>/dev/null || echo "$ROOT")
APPROVALS_REAL=$(realpath -m "$APPROVALS_FILE" 2>/dev/null || echo "$APPROVALS_FILE")
STATE_REAL=$(realpath -m "$STATE_FILE" 2>/dev/null || echo "$STATE_FILE")

# (a) 承認記録ファイル自体への書き込みは常に禁止（エージェントは自己承認できない）
if [ "$FILE_REAL" = "$APPROVALS_REAL" ]; then
  echo "R5 違反: gate_approvals.json はエージェントが書き換えできません（Human/CI のみ。自己承認防止）"
  exit 1
fi

# (b)(c) state.json 以外への書き込みは対象外
[ "$FILE_REAL" != "$STATE_REAL" ] && exit 0

CURRENT_PHASE=$(jq -r '.phase // "UNKNOWN"' "$STATE_FILE" 2>/dev/null)

# 現在の PRODUCT.md ハッシュを算出するヘルパ
current_product_hash() {
  if [ -f "$PRODUCT_FILE" ] && command -v sha256sum >/dev/null 2>&1; then
    echo "sha256:$(sha256sum "$PRODUCT_FILE" | awk '{print $1}')"
  else
    echo ""
  fi
}

# CLARIFY 以外では本ゲートの対象外（CLARIFY→DESIGN のみが必須 Human ゲート）。
[ "$CURRENT_PHASE" != "CLARIFY" ] && exit 0

# 承認済みか判定。
APPROVAL=$(jq -r '.CLARIFY_TO_DESIGN.approved_by // empty' "$APPROVALS_FILE" 2>/dev/null)
if [ -n "$APPROVAL" ]; then
  # (c) 承認時点の PRODUCT.md ハッシュと現在を照合する。
  REC_HASH=$(jq -r '.CLARIFY_TO_DESIGN.product_md_hash // empty' "$APPROVALS_FILE" 2>/dev/null)
  if [ -n "$REC_HASH" ]; then
    CUR_HASH=$(current_product_hash)
    if [ "$REC_HASH" = "$CUR_HASH" ]; then
      exit 0    # 承認済み・仕様も承認時から不変 → 許可
    fi
    echo "R5 違反: 承認後に PRODUCT.md が変更されています（承認=$REC_HASH / 現在=$CUR_HASH）。"
    echo "         V2: clarifier サブエージェント経由で gate_approvals.CLARIFY_TO_DESIGN を再承認してください。"
    echo "         (v1 scripts/approve-gate.sh は §11.2 R-2a-1 で削除済み)"
    exit 1
  fi
  # ハッシュ未記録の承認（後方互換）→ 従来通り許可
  exit 0
fi

# 未承認。書き込み内容を解析し、phase を CLARIFY 以外へ変えようとしているかを判定する。
#   Write  → tool_input.content（ファイル全文）
#   Edit   → tool_input.new_string（置換後テキスト）
INPUT="${1:-}"
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null)

if [ -z "$CONTENT" ]; then
  # 内容を取得できない（Bash 経由の jq+mv 等）→ phase 改変の可能性を排除できない → fail-closed
  echo "R5 違反: CLARIFY 中の state.json 書き込み内容を確認できません（Human 承認なし・改ざん防止のため拒否）"
  exit 1
fi

# 内容に「phase を CLARIFY 以外へ設定する記述」が含まれるなら deny。
# 例: "phase": "DESIGN" / 'phase':'EXECUTE' など。CLARIFY のままなら許可。
if echo "$CONTENT" | grep -qiE '"?phase"?[[:space:]]*[:=][[:space:]]*"?[A-Za-z_]+"?' ; then
  PHASE_VAL=$(echo "$CONTENT" \
    | grep -oiE '"?phase"?[[:space:]]*[:=][[:space:]]*"?[A-Za-z_]+"?' \
    | head -1 \
    | grep -oiE '[A-Za-z_]+"?$' | tr -d '"')
  if [ -n "$PHASE_VAL" ] && [ "$PHASE_VAL" != "CLARIFY" ]; then
    echo "R5 違反: CLARIFY→$PHASE_VAL のゲート越えには Human 承認が必要です（sprint/gate_approvals.json に未記録）"
    exit 1
  fi
fi

# phase を変えない通常の state.json 更新（resume_hint 等）は CLARIFY 中でも許可。
exit 0
