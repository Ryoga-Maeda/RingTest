# 改善フェーズ ブリーフ（planner 向け構造化材料）

> 生成日時: 2026-06-17T15:45:00Z
> 調査者: investigator
> 対象スプリント: sprint-1
> 入力: sprint/IMPROVE_FINDINGS.md（9 件）
> サマリ: P1=3, P2=3, P3=3, 未確認落とし=0

---

## 0. 本ブリーフの取り扱い（auto モード簡略化方針）

**重要**: 本スプリント (sprint-1 / RingTest) は **V2 アーキテクチャ機構の実機テスト** が主目的であり、
改善ループそのものは **TRIAGE → AskUserQuestion → 中止判断** の経路で短絡してテスト完走させる方針。
したがって本 BRIEF は **planner / designer に渡されることなく** 以下の用途に限定される:

1. investigator → AskUserQuestion 系の意思決定で「Human が中止判断を下す材料」として提示する
2. 発掘された 9 件の根本原因と修正提案を、**ClaudeRing 本体側（テンプレ・スクリプト・規約）の改修課題**として後日参照する
3. V2 機構（TRIAGE 経路・investigator / clarifier / designer / decomposer / improver の I/F・PhaseAdvance フック動作）の検証成果物として残す

→ **本スプリント内では I-001〜I-009 の修正実装は行わない**。修正反映先は `ClaudeRing` テンプレ側 (`.claude/sprint/*`, `templates/*`, `scripts/*`) または将来別スプリントとする。

---

## 1. 全体傾向

bug-hunter が発掘した 9 件は概ね 3 つの傾向に分類できる:

- **傾向 A: 合格基準（AC）の検証手段が PRODUCT 成功条件の原意を覆い切れていない (F-001 / F-002 / F-003 / F-006 / F-007)**
  - AC は「単発 jq / grep ワンライナーで判定する」(D-2) 方針が、PRODUCT 側の「遷移が起きた」「フックが起動した」というイベント性要件と乖離。
  - 特に F-001 は **AC-1 自体が時間発展で必ず FAIL に転ずる検証式** という構造欠陥。これは evaluator が VERIFY 時点で PASS としても TRIAGE で再実行すれば矛盾する。
- **傾向 B: state.json の Single Source of Truth が分裂している (F-004 / F-008)**
  - 個別 task-*.status.json の COMPLETE が state.json.tasks.* に伝播しない。
  - checkpoint.md が初期状態のまま放置され、resume_hint.read_first が古い指示を読ませる。
- **傾向 C: 文書資産・evidence の信頼性低下 (F-005 / F-009)**
  - evidence.verify_command が相対パスで再現不能。
  - DECISIONS.md が空（SPRINT.md §4 の D-1〜D-5 が転記されていない）。

**既存設計との齟齬**:
- F-001/F-002/F-003: SPRINT.md §1 備考 (25-31 行) で「成功条件 3 / 5 は AC-1 で間接的に検証される」と D-1 (75-82) が宣言しているが、`phase_advance_last_fired_at: 0` の実機状態は「フックが起動した痕跡が無い」ことを示しており、間接検証の前提が崩れている。
- F-004: V2 ヘッダ §状態の外部化（Single Source of Truth）原則と矛盾。
- F-005: SPRINT.md §1 AC-2 の検証手段は絶対パス。evidence への転記時に縮約された。

---

## 2. 修正完了の必要条件（design への提案）

将来 ClaudeRing 本体側または別スプリントで改善を行う場合、修正後に以下を満たすこと:

- **NC-1 (検証手段の時間不変性)**: 合格基準の検証手段は、VERIFY 時点と TRIAGE 時点で同じ結果を返さねばならない（時間発展で結果が変わらない）。
- **NC-2 (フック起動の直接検査)**: PRODUCT 成功条件 4 を満たすには、`phase_advance_last_fired_at != 0` を直接検査する AC が必要。
- **NC-3 (状態同期不変条件)**: 各 task の status は、state.json.tasks.*.status と task-*.status.json で常に一致する（書込窓口でアトミックに反映）。
- **NC-4 (evidence の絶対パス強制)**: worker が記録する evidence.verify_command は SPRINT.md §1 の検証手段を文字列として転記し、絶対パスを維持する。

---

## 3. 修正項目テーブル

| ID | 症状 | 根本原因 | 影響範囲 (touches) | 失敗分類 | 優先度 | 関連 finding | 関連実装タスク | 反映先 |
|----|------|----------|-------------------|----------|--------|--------------|----------------|--------|
| I-001 | AC-1 検証式が時間発展で FAIL に転ずる | 検証手段が `.phase` の現在値を直接読むため、phase が DESIGN 以降に進むと必ず期待値と乖離する。SPRINT.md §1 D-5 (AC-1 統合) が時間不変性を考慮していない | sprint/SPRINT.md §1 AC-1, sprint/SPRINT.md §4 D-5 | 仕様欠落（合格基準の構造欠陥） | P1 | F-001 | task-1 (AC-2 整合性自己確認) | ClaudeRing テンプレ: designer プロンプトに「合格基準は時間不変であること」を追記 |
| I-002 | AC-1 が「遷移イベント」を検査せず「現在値」のみ見る | SPRINT.md §1 備考 (25-27 行) が designer の意図で「維持されている」へ弱められ、PRODUCT.md 成功条件 2 / 4 の遷移イベント要件と乖離 | sprint/SPRINT.md §1 AC-1, sprint/PRODUCT.md §成功条件 (34-39 行) との照合 | 要件曖昧（CLARIFY 段階で解釈差を埋めるべき案件） | P1 | F-002 | task-1 | ClaudeRing テンプレ: clarifier プロンプトに「成功条件のイベント性 vs 状態性を明示分離せよ」を追記 |
| I-003 | `phase_advance_last_fired_at` が 0 のまま更新されない | PhaseAdvance フック (`scripts/phase-advance-apply.sh`) の実装、または state.json への書込窓口でこのフィールドの更新ロジックが欠落／呼ばれていない可能性 | scripts/phase-advance-apply.sh (ClaudeRing 本体), sprint/state.json | 実装欠陥（フック層の欠陥）または環境欠陥 | P1 | F-003 | （実装タスクとは独立。インフラ層） | ClaudeRing 本体: PhaseAdvance フックの更新ロジック調査・修正 |
| I-004 | state.json.tasks.*.status が PENDING のまま、task-*.status.json は COMPLETE | EXECUTE → INTEGRATE 経路で task の COMPLETE 状態を state.json へ反映する書込窓口が存在しない、または呼ばれていない | sprint/state.json, sprint/tasks/task-*.status.json | 実装欠陥（書込窓口の同期欠落） | P2 | F-004 | task-1, task-2 両方 | ClaudeRing 本体: repo-mgr / worktree-mgr の MERGE 完了時に state.json.tasks.*.status を COMPLETE / MERGED へ更新する処理を追加 |
| I-005 | task-1.status.json の evidence.verify_command が相対パス | worker プロンプトまたは evidence 記録ロジックで SPRINT.md §1 検証手段を文字列転記する際にパスが縮約された | sprint/tasks/task-1.status.json | 実装欠陥（worker の evidence 記録規約） | P2 | F-005 | task-1 | ClaudeRing テンプレ: worker プロンプトに「verify_command は SPRINT.md の検証手段を文字単位で転記せよ」を明記 |
| I-006 | AC-3 検証手段が「ちょうど 1 行」を保証していない | SPRINT.md §1 AC-3 検証手段 `grep -cx ...` のみで `wc -l` 併用が抜けている。task-2.md §TDD 手順では正しく併用しているが、合格基準側に反映されていない | sprint/SPRINT.md §1 AC-3 | 仕様欠落（検証手段の不完全性） | P2 | F-006 | task-2 | ClaudeRing テンプレ: designer プロンプトに「『ちょうど N 行』『ちょうど N 個』要件は wc -l / wc -w を併用せよ」のチェック項目を追記 |
| I-007 | PRODUCT 成功条件 5 (fail-closed エラー皆無) の直接検査が無い | SPRINT.md §1 D-1 が成功条件 5 を AC-1 へ吸収した設計判断が、resilience フィールドの直接検査を不要としているが、PRODUCT 原意との乖離が残る | sprint/SPRINT.md §1, sprint/PRODUCT.md §成功条件 5 | 要件曖昧 → 仕様欠落 | P3 | F-007 | （AC 全体） | ClaudeRing テンプレ: designer プロンプトに「成功条件を AC に吸収する判断は理由と検証式で明示せよ」を追記（既に D-1 で明示済みだが検査式が必要） |
| I-008 | sprint/checkpoint.md が古い | checkpoint.md を更新する責務エージェントが未定義、または更新トリガが PhaseAdvance フックに紐付いていない | sprint/checkpoint.md, sprint/state.json.resume_hint | 実装欠陥（チェックポイント更新層の欠陥） | P3 | F-008 | （フェーズ間） | ClaudeRing 本体: PhaseAdvance フックで checkpoint.md を機械的に更新するか、あるいは resume_hint.read_first から外す |
| I-009 | sprint/DECISIONS.md が空 | DESIGN フェーズで designer が SPRINT.md §4 に D-1〜D-5 を記述したが、DECISIONS.md への転記責務が誰にも割当されていない | sprint/DECISIONS.md | 仕様欠落（責務未定義） | P3 | F-009 | （DESIGN 成果物） | ClaudeRing テンプレ: designer プロンプトに「SPRINT.md §4 の D-* を DECISIONS.md へ転記」または「DECISIONS.md は使わず SPRINT.md §4 を SoT とする」を明記 |

---

## 4. 失敗分類の集計

- **仕様欠落** (4 件): I-001, I-006, I-007, I-009
- **実装欠陥** (4 件): I-003, I-004, I-005, I-008
- **要件曖昧** (1 件): I-002
- **環境欠陥**: 0
- **回帰**: 0

→ 全体として **テンプレ・規約レベルの不足が支配的**。ClaudeRing 本体側のプロンプト・スクリプト改修で全件対応可能。

---

## 5. 依存・順序ヒント（DAG）

```
[ClaudeRing 本体テンプレ改修側]
I-001 ─┐
I-002 ─┼─→ I-006 (検証手段の構造改善)
I-007 ─┘

I-005 (worker evidence 規約)  ── 独立
I-009 (designer 責務追記)     ── 独立

[ClaudeRing 本体スクリプト改修側]
I-003 ─→ I-008 (PhaseAdvance フック周辺)
I-004           ── 独立（書込窓口追加）
```

---

## 6. 再現性検証で落とした finding

なし（9 件すべて bug-hunter の再現手順で実機再現可能）。

---

## 7. 既存実装タスクとの紐付け

- task-1 (AC-2 SPRINT.md/PRODUCT.md 整合性自己確認) ←→ I-001, I-002, I-005
- task-2 (AC-3 smoke.txt 生成) ←→ I-006
- 実装タスクに紐付かない（フェーズ・インフラ層）: I-003, I-004, I-007, I-008, I-009

---

## 8. 改善フェーズの推奨スコープ

### 本スプリント内（sprint-1 / RingTest）
- **実施しない**。auto モード簡略化方針に従い、TRIAGE で AskUserQuestion し中止判断とする。
- 理由: 本スプリントの主目的は V2 機構の実機テストであり、改善ループ実行は副次的。BRIEF を残すこと自体が investigator → clarifier I/F の検証成果物となる。

### ClaudeRing 本体側で後日対応（推奨優先度）
- **必須 (P1)**: I-001 (AC 時間不変性), I-002 (clarifier プロンプト改善), I-003 (PhaseAdvance フック調査)
- **推奨 (P2)**: I-004 (state 同期窓口), I-005 (worker evidence 規約), I-006 (designer プロンプト改善)
- **任意 (P3)**: I-007, I-008, I-009 (文書資産・盲点)

---

## 9. Human への確認事項

**主要判断**: 本スプリント (sprint-1 / RingTest) で TRIAGE → IMPROVE への遷移を承認するか、中止判断とするか。

- **選択肢 A (推奨)**: 中止判断。改善ループは実行せず本スプリントを終了。発掘された 9 件は ClaudeRing 本体側課題として記録し、別スプリント or テンプレ改修で対応。
  - 利点: V2 機構の実機テスト目的を既に達成（CLARIFY → DESIGN → PLAN → EXECUTE → VERIFY → INTEGRATE → COMPLETE → TRIAGE の経路と investigator I/F が動作確認できた）。改善ループの追加実行は同じ I/F の繰り返し検証となり、新規検証情報が少ない。
  - 欠点: 改善ループ (TRIAGE → IMPROVE → DESIGN → PLAN → EXECUTE → VERIFY → INTEGRATE → COMPLETE) の I/F は未検証のまま。
- **選択肢 B**: 改善ループを実行。本 BRIEF を planner に渡し DESIGN/PLAN/EXECUTE/VERIFY を回す。
  - 利点: 改善ループ I/F の実機検証。
  - 欠点: 修正対象の多くが ClaudeRing 本体側であり、RingTest 内では完結しない（INV-4 スコープ外不侵入と衝突）。RingTest 内で完結する修正のみに絞ると task-1 / task-2 の微修正に限定され実質的価値が薄い。

→ investigator は **選択肢 A (中止判断)** を推奨する。

---

## 10. メタ情報

- 本 BRIEF は 1 ファイルで完結。追加詳細根拠ファイルは生成していない（finding 側の根拠で十分）。
- state.json への書込: `triage_artifacts.brief_path = "sprint/IMPROVE_BRIEF.md"` および `p1_count/p2_count/p3_count` は既に bug-hunter 段階で 3/3/3 が記録済み（state.json:50-57）。investigator は brief_path のみ更新する。
