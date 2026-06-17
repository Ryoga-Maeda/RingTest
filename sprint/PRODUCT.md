# PRODUCT: ClaudeRing V2 実機動作テスト (RingTest)

## 目的

ClaudeRing V2 自律スプリント開発アーキテクチャの主要構成要素が、
実機 (RingTest リポジトリ) 上で壊れずに連携動作することを段階的に検証する。
本スプリントでは特に「CLARIFY → DESIGN 遷移」までを最小成果物 (MVP)
として扱い、以下 4 点が壊れていないことを確認することをゴールとする。

1. `deploy-sprint.sh` による決定論的な同期（再実行で差分が出ない）
2. `SessionStart` / `PhaseAdvance` フックが意図通りに起動する
3. `phase-advance-eval` が現フェーズに応じた次手指示を生成する
4. サブエージェント連携 (Task ツール経由の clarifier 起動・成果物 Write) が成立する

## 利用者像

- **一次利用者**: ClaudeRing V2 アーキテクチャの開発者・メンテナ
  - 目的: アーキテクチャ改修後のリグレッション検出、フック層と
    フェーズエージェントの結線確認、決定論性の担保確認。
  - 期待: 実機テストで問題が早期に顕在化し、根本原因が
    state.json / フック ログ / サブエージェント出力のいずれに
    あるか切り分けやすいこと。
- **二次利用者**: 将来 V2 テンプレートを fork する開発者
  - 目的: 「正しく動く参照系」として RingTest のスプリント記録を
    読み、自分の環境で再現できるかの判断材料にする。

## 成功条件 (Acceptance Criteria)

本スプリントは以下をすべて満たしたとき成功とみなす。

1. `sprint/PRODUCT.md` (本ファイル) が新規生成され、必須 4 セクション
   (目的 / 利用者像 / 成功条件 / スコープ外) を満たしている。
2. Human ゲート `CLARIFY_TO_DESIGN` が承認され、
   `sprint/state.json` の `gate_approvals.CLARIFY_TO_DESIGN` が
   `true` に遷移する（書込は Orchestrator が実施）。
3. `PhaseAdvance` フックが起動し、`phase-advance-eval` が
   次フェーズ (DESIGN) への遷移指示を生成する。
4. `state.json` の `phase` フィールドが `CLARIFY` → `DESIGN` に
   遷移し、`phase_advance_last_fired_at` が更新される。
5. 上記 1〜4 の過程で、フック / サブエージェント / state 書込窓口の
   いずれにも fail-closed エラー（規律違反・schema 不整合等）が
   発生していない。

## スコープ外 (Non-Goals)

本スプリントでは以下は扱わない（後続スプリントの責務）。

- DESIGN フェーズ以降 (PLAN / EXECUTE / VERIFY / INTEGRATE / COMPLETE)
  の実機検証。今回は CLARIFY → DESIGN 遷移の成立確認までで打ち切る。
- 改善ループ (TRIAGE / improve sub_phase / IMPROVE_BRIEF.md 生成)
  の動作検証。
- `deploy-sprint.sh` 自体のリファクタや機能追加。本スプリントは
  「既存の決定論同期が壊れていないか」の確認のみで、改修は行わない。
- フック層 (SessionStart / PhaseAdvance / PreToolUse) の新規追加・
  仕様変更。今回は起動と既存挙動の確認のみ。
- 規律 ID (R0〜R6) の新規追加・改定。
- ESCALATION 経路 (failure_count 3 / 規律違反 3 超) の発火検証。
- 性能計測・ベンチマーク・並列スプリントの検証。
- ドキュメント (README.md / ARCHITECTURE_GUIDE.md) の改訂。
