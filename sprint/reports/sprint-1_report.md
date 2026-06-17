# Sprint Report: sprint-1 (ClaudeRing V2 実機動作テスト / RingTest)

> 生成日時: 2026-06-17T15:50:00Z（completer フェーズ完了レポート）
> 対象スプリント: sprint-1
> 経路: CLARIFY → DESIGN → PLAN → EXECUTE → VERIFY → INTEGRATE → COMPLETE → TRIAGE → COMPLETE
> 結論: **完走（合格基準 3/3 全 PASS、改善ループは out-of-scope として中止）**

---

## 1. サマリ（3 行）

- 本スプリントは ClaudeRing V2 アーキテクチャの主要構成要素（deploy-sprint.sh の決定論同期 / SessionStart・PhaseAdvance フック / サブエージェント連携）の実機疎通を CLARIFY → DESIGN 遷移を中心に検証し、AC-1 / AC-2 / AC-3 を全 PASS で完了した。
- VERIFY 後の bug-hunter による掘り下げで 9 件の構造的ギャップ（AC 検証手段の時間不変性欠如・state.json の SoT 分裂・evidence 信頼性低下など）が発掘されたが、これらは ClaudeRing **本体側**のテンプレ・スクリプト改修課題であり、INV-4（スコープ外不侵入）に従い本スプリント内では修正しない判断（選択肢 A）を確定。findings / brief は保全。
- PR は GitHub 側で作成済み（[PR #1](https://github.com/Ryoga-Maeda/RingTest/pull/1)）、archive と report を生成して COMPLETE。後続アクションは「スプリント完了通知 → ClaudeRing 本体側の I-001 〜 I-009 改修を別スプリント or 次回テンプレ改修で対応」。

---

## 2. 達成した合格基準（Acceptance Criteria）

SPRINT.md §1 の 3 基準すべてが evaluator 採点で PASS。state.json の `evaluator_scores` に記録済み。

| 基準 ID | 内容 | 採点 | 検証手段 |
| --- | --- | --- | --- |
| AC-1 | CLARIFY → DESIGN 遷移が state.json に反映されている（PRODUCT.md 成功条件 2 / 4） | **PASS** | `jq -r '.phase + "/" + (.gate_approvals.CLARIFY_TO_DESIGN \| tostring)' sprint/state.json` |
| AC-2 | PRODUCT.md / SPRINT.md が両方存在し必須見出しを含む（PRODUCT.md 成功条件 1） | **PASS** | `test -s sprint/PRODUCT.md && test -s sprint/SPRINT.md && grep -q '^## スコープ外' sprint/PRODUCT.md && grep -q '^## 1\. 合格基準表' sprint/SPRINT.md && echo OK` |
| AC-3 | スモークマーカー `sprint/artifacts/smoke.txt` が定型行 `ringtest-smoke-ok` を 1 行含む | **PASS** | `grep -cx 'ringtest-smoke-ok' sprint/artifacts/smoke.txt` |

達成基準数: **3 / 3**（全 PASS）

PRODUCT.md 成功条件 3（PhaseAdvance フック起動）と 5（fail-closed エラー皆無）は SPRINT.md §1 備考と D-1 に従って AC-1 へ吸収・間接検証とした（直接検査は本スプリントの最小スモーク方針外）。

---

## 3. PR / 統合情報

- **PR URL**: <https://github.com/Ryoga-Maeda/RingTest/pull/1>
- **state.json.integrate.pr_url**: `https://github.com/Ryoga-Maeda/RingTest/pull/1`
- **integrate フェーズ実施日**: 2026-06-17（state.json.started_at: 2026-06-17T15:00:00Z 起点）
- **merge 状態**: PR は作成済み（マージ可否は本レポート対象外）

---

## 4. フェーズ遷移サマリ

| フェーズ | 主担当 | 主成果物 |
| --- | --- | --- |
| CLARIFY | clarifier | `sprint/PRODUCT.md`（目的 / 利用者像 / 成功条件 5 件 / スコープ外） |
| DESIGN | designer | `sprint/SPRINT.md`（AC-1〜AC-3 / 並列度 2 / INV-1〜INV-6 / D-1〜D-5） |
| PLAN | decomposer | `sprint/tasks/task-1.md`（AC-2 自己確認）/ `task-2.md`（AC-3 smoke.txt 生成） |
| EXECUTE | worker × 2（並列） | `sprint/artifacts/smoke.txt`（`ringtest-smoke-ok` 1 行） / task-*.status.json |
| VERIFY | evaluator | `state.json.evaluator_scores = {AC-1: PASS, AC-2: PASS, AC-3: PASS}` |
| INTEGRATE | integrator | PR #1（`state.json.integrate.pr_url`） |
| COMPLETE → TRIAGE | bug-hunter / investigator | `sprint/IMPROVE_FINDINGS.md`（9 件）/ `sprint/IMPROVE_BRIEF.md`（I-001〜I-009） |
| TRIAGE → COMPLETE | Human 判断 → completer | p1=p2=0 reset、本レポート + archive 生成 |

並列度 2 の経路（worktree-mgr 経由）は AC-2 用 task-1 と AC-3 用 task-2 を独立 touches（`sprint/SPRINT.md` / `sprint/artifacts/smoke.txt`）で同時実行し、競合なく完了。

---

## 5. Findings の取り扱い（out-of-scope 保全）

bug-hunter は 9 件の構造的ギャップを発掘し（`sprint/IMPROVE_FINDINGS.md`）、investigator が修正項目 I-001〜I-009 として整理（`sprint/IMPROVE_BRIEF.md`）。これらの 9 件は **本スプリント (RingTest) 内の修正対象ではなく、ClaudeRing 本体側のテンプレ・スクリプト改修課題**と判定された。

- **判定根拠**: PRODUCT.md `## スコープ外` および INV-4（スコープ外不侵入）。修正対象の touches が `.claude/sprint/*` / `templates/*` / `scripts/phase-advance-apply.sh` 等 ClaudeRing 本体側に集中しており、RingTest 内で完結する修正は task-1 / task-2 の微修正に限定され実質的価値が薄い。
- **Human 判断**: 選択肢 A（改善ループ中止判断）を承認、`triage_artifacts.p1_count` / `p2_count` を 0 にリセット。
- **保全状態**: `sprint/IMPROVE_FINDINGS.md`（9 件・bug-hunter 原本）および `sprint/IMPROVE_BRIEF.md`（I-001〜I-009 構造化 / out-of-scope 注記入り冒頭ブロック付き）は archive 配下にコピーされ、ClaudeRing 本体側の改修参考資料として永続保全される。

### 後日 ClaudeRing 本体側で対応すべき優先順（推奨）

| 優先度 | ID | 概要 |
| --- | --- | --- |
| P1 | I-001 | AC 検証手段の時間不変性（designer プロンプトに「合格基準は時間不変であること」追記） |
| P1 | I-002 | clarifier プロンプトに「成功条件のイベント性 vs 状態性を明示分離せよ」追記 |
| P1 | I-003 | PhaseAdvance フック (`scripts/phase-advance-apply.sh`) で `phase_advance_last_fired_at` 更新ロジック調査・修正 |
| P2 | I-004 | task COMPLETE 状態を state.json.tasks.* へ反映する書込窓口追加 |
| P2 | I-005 | worker プロンプトに「evidence.verify_command は SPRINT.md 検証手段を文字単位で転記、絶対パス維持」追記 |
| P2 | I-006 | designer プロンプトに「『ちょうど N 行』要件は wc -l 併用」チェック項目追記 |
| P3 | I-007 | 成功条件 AC 吸収判断の検査式明示 |
| P3 | I-008 | checkpoint.md 更新層の整備または resume_hint から除外 |
| P3 | I-009 | DECISIONS.md 転記責務の明文化（または SPRINT.md §4 を SoT 化） |

---

## 6. 学び・教訓（V2 機構実機テスト結果）

本スプリントが「V2 機構の最初の実機投入」となったことで、以下の G1-G6 ギャップが明らかになった（詳細は PR #1 添付の `V2_SMOKE_TEST_REPORT.md` を参照）。本レポートでは要点のみ概略。

- **G1 (合格基準の時間不変性)**: AC-1 のように `.phase` 現在値を見る検証式は VERIFY 時点で PASS でも TRIAGE 時点で必ず FAIL に転ずる構造を持つ。合格基準は「フェーズが進んでも結果が変わらない時間不変式」で書く必要がある（→ I-001）。
- **G2 (PRODUCT イベント性要件と AC 状態性検証の乖離)**: 「遷移が起きた」「フックが起動した」というイベント性要件を、現在値ベースの AC で覆おうとすると意味的乖離が発生する。CLARIFY 段階でイベント性 vs 状態性を明示分離する必要（→ I-002）。
- **G3 (PhaseAdvance フックの観測痕跡欠落)**: `phase_advance_last_fired_at` が 0 のまま運用フェーズが 7 回進行した。フックは動いているが副作用記録の更新ロジックが欠落 or 未呼び出し（→ I-003）。
- **G4 (state.json SoT 分裂)**: 個別 task-*.status.json の COMPLETE が state.json.tasks.* に伝播しない。V2 ヘッダ「状態の外部化（Single Source of Truth）」原則と矛盾（→ I-004）。
- **G5 (evidence 信頼性低下)**: worker が evidence.verify_command を相対パスで縮約記録し、再現実行で失敗。SPRINT.md §1 の絶対パス検証手段を文字単位で転記する規約が必要（→ I-005）。
- **G6 (文書資産責務未定義)**: DECISIONS.md が空 / checkpoint.md が初期状態のまま放置。SPRINT.md §4 の D-* を DECISIONS.md へ転記する責務、checkpoint.md の更新責務が未定義（→ I-008 / I-009）。

これらは **V2 アーキテクチャの「最初の実機適用」でしか顕在化しないクラスのバグ**であり、本スプリントを実行した最大の価値は「テンプレ層・規約層の不足を実機で炙り出せた」点にある。改善対象を ClaudeRing 本体側に切り分けたことで、テンプレ改修の作業項目（I-001〜I-009）が明確化された。

---

## 7. アーカイブ

本スプリントの主要成果物は以下にアーカイブされる（completer フェーズで生成）。

- ディレクトリ: `sprint/archive/sprint-1/`
- 圧縮: `sprint/archive/sprint-1.tar.gz`
- 含まれるファイル:
  - `SPRINT.md`
  - `PRODUCT.md`
  - `tasks/task-1.md`, `tasks/task-2.md`
  - `IMPROVE_FINDINGS.md`（9 件の findings）
  - `IMPROVE_BRIEF.md`（I-001〜I-009、out-of-scope 注記入り）

---

## 8. 後続アクション

1. **スプリント完了通知**: Orchestrator / Human にスプリント完了を通知（本レポートと archive パスを参照）。
2. **ClaudeRing 本体側の改修課題化**: I-001 (P1) / I-002 (P1) / I-003 (P1) を最優先で別スプリント or テンプレ改修として起票。
3. **次回スプリント候補**: DESIGN 以降のフェーズ（PLAN / EXECUTE / VERIFY / INTEGRATE / COMPLETE）の実機検証、または改善ループ（TRIAGE → IMPROVE → DESIGN → ...）の本格 I/F 検証は PRODUCT.md スコープ外として本スプリントでは扱わなかったため、後続スプリントの主目的候補となる。
