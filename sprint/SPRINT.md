# SPRINT: ClaudeRing V2 実機動作テスト (RingTest) 設計書

本 SPRINT.md は DESIGN フェーズ成果物。PRODUCT.md の成功条件 (Acceptance Criteria) を
「evaluator が実機で動かせる検証手段」に変換し、合格基準・並列性・不変条件・設計判断
を最小スコープで定義する。

スコープ: PRODUCT.md の Non-Goals に従い、CLARIFY → DESIGN 遷移の成立確認までを
スモークテスト相当で検証する。実装作業は最小限（マーカーファイル生成 + state.json の整合性確認）
に限定する。

---

## 1. 合格基準表 (Acceptance Criteria Table)

evaluator は本セクションの「検証手段」を bash でそのまま実行し、「期待結果」と一致するか
を確認することで合否判定する。すべての検証は `/home/user/RingTest` を CWD とする前提。

| 基準 ID | 内容 | 検証手段 (Bash) | 期待結果 |
| --- | --- | --- | --- |
| AC-1 | CLARIFY → DESIGN 遷移が state.json に反映されている (PRODUCT.md 成功条件 2 / 4 に対応) | `jq -r '.phase + "/" + (.gate_approvals.CLARIFY_TO_DESIGN \| tostring)' /home/user/RingTest/sprint/state.json` | 標準出力が `DESIGN/true` であること (phase が DESIGN かつ CLARIFY_TO_DESIGN ゲートが承認済み) |
| AC-2 | CLARIFY 成果物 (PRODUCT.md) と DESIGN 成果物 (SPRINT.md) が両方存在し、必須セクション見出しを含む (PRODUCT.md 成功条件 1 に対応) | `test -s /home/user/RingTest/sprint/PRODUCT.md && test -s /home/user/RingTest/sprint/SPRINT.md && grep -q '^## スコープ外' /home/user/RingTest/sprint/PRODUCT.md && grep -q '^## 1\. 合格基準表' /home/user/RingTest/sprint/SPRINT.md && echo OK` | 標準出力が `OK` の単一行で終了コード 0 |
| AC-3 | スモーク実装マーカー (`sprint/artifacts/smoke.txt`) が生成され、定型行を 1 行だけ含む (実装系の最小疎通) | `test -f /home/user/RingTest/sprint/artifacts/smoke.txt && grep -cx 'ringtest-smoke-ok' /home/user/RingTest/sprint/artifacts/smoke.txt` | 標準出力が `1` で終了コード 0 (定型行 `ringtest-smoke-ok` がちょうど 1 行) |

備考:
- AC-1 は PRODUCT.md 成功条件 2 / 4 を 1 つの判定式に統合している (本スプリント時点で
  state.json の `phase` は既に `DESIGN`、`gate_approvals.CLARIFY_TO_DESIGN` は既に `true` に
  なっている想定。evaluator はこれが「DESIGN フェーズ完了時点でも維持されている」ことを確認する)。
- PRODUCT.md 成功条件 3 (PhaseAdvance フックが起動して次手指示を生成する) と
  成功条件 5 (fail-closed エラーが発生しない) は、本スプリントでは
  AC-1 の `phase=DESIGN` 到達によって間接的に検証される (フック層が機能しなければ
  phase 書込が起きないため)。直接の hook ログ検査は後続スプリントの責務とする。

---

## 2. 並列性 (Parallelism)

- 並列度: **2 並列**
- 並列実行可否:
  - **可**: AC-2 用の SPRINT.md 整形作業 と AC-3 用のスモークマーカー (`sprint/artifacts/smoke.txt`) 生成は
    書込先ファイルが互いに重ならないため、並列タスクとして同時に decomposer が割り当て可能。
  - **不可**: AC-1 は state.json の読取のみで evaluator フェーズで検証されるため、
    実装フェーズでは独立タスクを発行しない (検証専用)。
- 並列タスク分割の想定 (decomposer 向けヒント):
  - task-1: AC-2 を満たす SPRINT.md / PRODUCT.md の整合性確認 (本ファイルが既に存在することの自己確認 + 必須見出し検査)
  - task-2: AC-3 を満たすスモーク実装 (`sprint/artifacts/smoke.txt` に `ringtest-smoke-ok` を 1 行だけ書く)

---

## 3. 不変条件 (Invariants)

DESIGN 以降のフェーズ・タスクは以下を常に維持しなければならない。違反は evaluator により即座に
不合格と判定される。

- **INV-1 (フェーズ単調性)**: `state.json.phase` は本スプリント期間中 `DESIGN` 以降に進む方向のみ更新される。
  CLARIFY への逆行は禁止 (規律 ID R2 相当)。
- **INV-2 (ゲート不可逆性)**: `state.json.gate_approvals.CLARIFY_TO_DESIGN` は一度 `true` になった後、
  本スプリント期間中に `false` へ戻してはならない。
- **INV-3 (書込窓口の独占)**: `state.json.phase` / `sub_phase` / `phase_advance_last_fired_at` の
  書込は `scripts/phase-advance-apply.sh` 経由のみ。フェーズ層エージェントは直接編集しない
  (V2 ヘッダ規約)。
- **INV-4 (スコープ外不侵入)**: PRODUCT.md `## スコープ外` に列挙された項目 (DESIGN 以降の実機検証、
  改善ループ、deploy-sprint.sh 改修、フック仕様変更、規律 ID 追加、ESCALATION 発火検証、性能計測、
  ドキュメント改訂) を変更するファイル編集は本スプリント内で行わない。
- **INV-5 (CLARIFY 成果物の凍結)**: DESIGN フェーズ以降、`sprint/PRODUCT.md` の内容は変更しない
  (本ファイルは CLARIFY 成果物として確定済み)。
- **INV-6 (アーティファクト局所性)**: 実装系の成果物は `sprint/artifacts/` 配下のみに置き、
  リポジトリルートを汚染しない。

---

## 4. 設計判断 (Design Decisions)

本スプリントの設計上の判断と、その根拠 (DECISIONS.md 風)。

### D-1: 合格基準を 3 個に圧縮する

- **判断**: PRODUCT.md の成功条件 1〜5 を、検証可能な合格基準 AC-1〜AC-3 の 3 個に集約する。
- **理由**: 本スプリントの目的は「V2 アーキテクチャ実機テスト」のスモークであり、
  PRODUCT.md 成功条件 3 / 5 (フック起動の直接ログ検査・fail-closed エラー皆無) は
  AC-1 の `phase=DESIGN` 到達に内包される (フック層が壊れていれば phase は遷移できない)。
- **代替案と却下理由**: 成功条件 1〜5 をそれぞれ別個の AC として定義する案は、検証コストが
  本スプリントの「最小スモーク」方針 (指示書: 合格基準 2〜3 個程度) に反するため却下。

### D-2: 検証手段はすべて単発 Bash ワンライナーで書く

- **判断**: 合格基準表の「検証手段」列はすべて bash で直接実行できる単一行コマンドとする。
  jq / grep / test を組み合わせ、外部スクリプトには依存しない。
- **理由**: evaluator サブエージェントが Bash ツールから直接呼び出して終了コードを確認できる
  形式が、責務分離 (designer は基準を書くだけ・evaluator は実行するだけ) に最も適合する。
- **代替案と却下理由**: 専用検証スクリプトを `scripts/verify-*.sh` として用意する案は、
  本スプリントのスコープ外 (deploy-sprint.sh 等のスクリプト改修禁止) と衝突するため却下。

### D-3: 並列度を 2 に設定する

- **判断**: 並列度を 2 並列とし、AC-2 と AC-3 を独立タスクとして同時実行できる構成にする。
- **理由**: 指示書で「実行系の検証も兼ねるため 2 並列を推奨」と明示されているため、
  worktree 並列実行系 (worktree-mgr) の正常動作確認も兼ねる。書込先ファイルが
  `sprint/SPRINT.md` (本ファイル・既存) と `sprint/artifacts/smoke.txt` (新規) で衝突しないため、
  並列実行による競合は発生しない。
- **代替案と却下理由**: 1 並列 (逐次) 案は worktree 並列系の疎通確認ができず、本スプリントの
  「実機テスト」目的に対する検証カバレッジが不足するため却下。

### D-4: スモーク実装の定型行を `ringtest-smoke-ok` に固定する

- **判断**: AC-3 のマーカーファイル `sprint/artifacts/smoke.txt` の内容は、
  改行終端 1 行の `ringtest-smoke-ok` という固定文字列に統一する。
- **理由**: 検証手段 `grep -cx 'ringtest-smoke-ok'` が「ちょうど 1 行」と一致することを期待し、
  揺らぎを排除する。本テストはタイムスタンプ・乱数を含めない (V2 ヘッダの揮発値禁止と整合)。
- **代替案と却下理由**: 実装日時等を含める案は揮発値となり、プロンプトキャッシュ整合性と
  決定論的検証の双方を損なうため却下。

### D-5: AC-1 の検証で `phase` と `gate_approvals` を 1 式に統合する

- **判断**: AC-1 の検証手段は `jq -r '.phase + "/" + (.gate_approvals.CLARIFY_TO_DESIGN | tostring)'`
  という単一式で `DESIGN/true` を期待する。
- **理由**: PRODUCT.md 成功条件 2 と 4 は本質的に「CLARIFY→DESIGN 遷移が完了したか」
  という 1 つの事実を 2 角度から表現しているため、検証も 1 つの jq 式に統合した方が
  evaluator のロジックが単純になり、規律 ID R3 (テスト失敗状態の commit 禁止) の
  判定も明瞭になる。
- **代替案と却下理由**: 2 個に分割する案は冗長で、合格基準数 2〜3 個の制約も圧迫するため却下。

---

## 5. 後続フェーズへの引き継ぎ事項

- **PLAN フェーズ (decomposer)**: 並列度 2 / 上記タスク分割ヒント (task-1: SPRINT.md 整合性自己確認、
  task-2: smoke.txt 生成) を採用すること。
- **EXECUTE フェーズ (worker)**: 不変条件 INV-3 を厳守し、state.json には直接書き込まない。
  成果物は `sprint/artifacts/` 配下に限定する (INV-6)。
- **VERIFY フェーズ (evaluator)**: 本ファイル §1 の Bash コマンドを順に実行し、
  終了コードと標準出力で AC-1 / AC-2 / AC-3 を判定する。判定結果は state.json の
  `evaluator_scores` に書き込む (V2 ヘッダ書込権限規約に従う)。
- **改善ループ**: PRODUCT.md `## スコープ外` により本スプリントでは扱わない。
