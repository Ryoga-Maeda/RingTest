# 発掘されたバグ・要件ミスマッチ（実装フェーズ完了時点）

> 生成日時: 2026-06-17T15:30:00Z
> 発掘者: bug-hunter
> 対象スプリント: sprint-1
> 照合元: sprint/SPRINT.md + 実装成果物 + state.json.evaluator_scores + 直接実機検証

---

## F-001: AC-1 検証手段の実行結果が SPRINT.md §1 の期待結果 `DESIGN/true` と一致しない（実行時は `TRIAGE/true`）— 設計欠陥 [P1]

- **症状の1行サマリ**: SPRINT.md §1 AC-1 の検証コマンドを実機で実行すると `TRIAGE/true` を返し、宣言された期待結果 `DESIGN/true` に一致しない。にもかかわらず evaluator_scores では `AC-1: PASS` となっている。
- **再現手順**:
  ```bash
  cd /home/user/RingTest
  jq -r '.phase + "/" + (.gate_approvals.CLARIFY_TO_DESIGN | tostring)' /home/user/RingTest/sprint/state.json
  # 出力: TRIAGE/true
  ```
- **期待される挙動**: SPRINT.md:20 (AC-1 行) は「標準出力が `DESIGN/true` であること」を期待結果として宣言している。本来この合格基準を実機で実行すれば `DESIGN/true` が返るべき。
- **観測された挙動**: `TRIAGE/true` が返る。`.phase` は既に TRIAGE まで進行している。
- **発掘時の根拠**: SPRINT.md:18-20、state.json:4 (`"phase": "TRIAGE"`)、phase_log.jsonl:1-7（DESIGN → PLAN → EXECUTE → VERIFY → INTEGRATE → COMPLETE → TRIAGE と単調進行）。
- **Evaluator 採点との関係**: PASS への再解釈。SPRINT.md §1 備考（25-27 行）で designer は「AC-1 は本スプリント期間中ずっと `DESIGN/true` に**維持されている**ことを確認する」と意図を述べているが、実際の検証コマンドは `.phase` フィールドをそのまま読むため、フェーズが進めば必ず `DESIGN/true` ではなくなる。これは AC-1 自体に内在する**絶対検証 vs 後続フェーズで再評価される設計欠陥**であり、evaluator が VERIFY 時点で一度通った後 TRIAGE で再実行すれば必ず FAIL になる仕様。

---

## F-002: SPRINT.md §1 備考の意図（CLARIFY→DESIGN 遷移の「成立」確認）と検証手段（現在の phase 値を読む）の意味的乖離 — 検証手段が「履歴」ではなく「現在値」を見ている [P1]

- **症状の1行サマリ**: PRODUCT.md 成功条件 2 / 4 は「CLARIFY→DESIGN 遷移が完了したこと」「`phase` が CLARIFY→DESIGN に遷移した（イベント）こと」を要求しているが、AC-1 の jq 式は「現在の `phase` が DESIGN であること」しか見ない。phase は CLARIFY→DESIGN 遷移後も進み続けるため、検証手段は遷移の発生（履歴・イベント）を一切確認できない。
- **再現手順**: PRODUCT.md §成功条件（27-42 行）と SPRINT.md AC-1 検証手段（20 行）を読み比べる。AC-1 の jq 式に履歴参照が一切無いことを確認。
- **期待される挙動**: 「CLARIFY → DESIGN 遷移が実際に起きた」ことを示す証拠（例: `phase_log.jsonl` に DESIGN エントリが存在する、`phase_advance_last_fired_at` が 0 以外、等）を検査すべき。
- **観測された挙動**: 検証手段は単一時点の `.phase` フィールドのみを参照するため、遷移イベントが起きたかどうかは検査できない。極端には phase が直接 DESIGN に書き込まれた（CLARIFY を経由しなかった）状態でも PASS になる。
- **発掘時の根拠**: PRODUCT.md:34-39（「`phase` フィールドが `CLARIFY` → `DESIGN` に遷移し」と遷移イベントを要求）、SPRINT.md:20（検証手段が現在値のみ）、SPRINT.md:25-27（備考が「維持されている」と現在値検証に弱めている）。
- **Evaluator 採点との関係**: PASS への再解釈。Evaluator は備考の弱めた解釈に従って採点しているが、PRODUCT.md の原意との乖離は埋まっていない。

---

## F-003: PRODUCT.md 成功条件 4 「`phase_advance_last_fired_at` が更新される」要件が満たされていない（値が 0 のまま）[P1]

- **症状の1行サマリ**: PRODUCT.md 成功条件 4 は「`phase_advance_last_fired_at` が更新される」ことを明示要求するが、state.json 上の値は `0` のまま一度も更新されていない。AC-1 の検証手段ではこのフィールドを見ないため見逃されている。
- **再現手順**:
  ```bash
  jq '.phase_advance_last_fired_at' /home/user/RingTest/sprint/state.json
  # 出力: 0
  ```
- **期待される挙動**: PhaseAdvance フックが発火するたびに `phase_advance_last_fired_at` が現在時刻（または非ゼロのカウンタ）に更新されるはず（PRODUCT.md:38-39）。少なくとも CLARIFY→DESIGN 遷移時に 1 度は非ゼロになるべき。
- **観測された挙動**: `phase_advance_last_fired_at: 0`（state.json:11）のまま。`phase_log.jsonl` には 7 個のフェーズ遷移が記録されているにもかかわらず、`phase_advance_last_fired_at` は更新されていない。
- **発掘時の根拠**: PRODUCT.md:38-39（成功条件 4 本文）、state.json:11、phase_log.jsonl:1-7（7 回の遷移）。
- **Evaluator 採点との関係**: AC-1 PASS の再解釈。AC-1 の検証手段はこのフィールドを覗かないため、PRODUCT.md 成功条件 4 の核心部分（フックが起動したことの痕跡）が検証されないまま PASS となっている。SPRINT.md §1 備考でも「成功条件 3 は AC-1 で間接的に検証される」と書かれているが、実際には間接的にも検証できていない。

---

## F-004: state.json.tasks の status が PENDING のままで、task-*.status.json の COMPLETE と不整合 [P2]

- **症状の1行サマリ**: 個別 `sprint/tasks/task-1.status.json` / `task-2.status.json` は `"status": "COMPLETE"` だが、`sprint/state.json` の `tasks.task-1.status` / `tasks.task-2.status` は `"PENDING"` のまま。Single Source of Truth が分裂している。
- **再現手順**:
  ```bash
  jq '.status' /home/user/RingTest/sprint/tasks/task-1.status.json   # "COMPLETE"
  jq '.tasks.task-1.status' /home/user/RingTest/sprint/state.json    # "PENDING"
  ```
- **期待される挙動**: V2 ヘッダ「状態の外部化（Single Source of Truth）」原則に照らし、state.json と個別 status.json の status は同一であるべき。少なくとも EXECUTE 完了時に state.json 側へ反映される設計でなければならない。
- **観測された挙動**: state.json:18-34 は PENDING のまま放置。`merged` も両方 false のまま。
- **発掘時の根拠**: state.json:18-34、task-1.status.json:3 / task-2.status.json:3、phase_log.jsonl:3-6（EXECUTE/VERIFY/INTEGRATE/COMPLETE まで通過済み）。
- **Evaluator 採点との関係**: Evaluator は state.json.evaluator_scores のみで PASS 判定しており、tasks ブロックの整合性は採点対象外。盲点。

---

## F-005: task-1.status.json の evidence.verify_command が相対パスで、再現実行すると失敗する [P2]

- **症状の1行サマリ**: `task-1.status.json` の `evidence.verify_command` は `test -s PRODUCT.md && test -s SPRINT.md && ...` と**リポジトリルートからの相対パス**を使っているが、ルートには `PRODUCT.md` / `SPRINT.md` は存在しない（実在は `sprint/PRODUCT.md` / `sprint/SPRINT.md`）。再現実行すると `exit=1` になる。
- **再現手順**:
  ```bash
  cd /home/user/RingTest
  test -s PRODUCT.md && test -s SPRINT.md && grep -q '^## スコープ外' PRODUCT.md && grep -q '^## 1\. 合格基準表' SPRINT.md && echo OK
  # 出力: なし / exit=1
  ```
- **期待される挙動**: evidence に記録されたコマンドは「いつでも再現可能」であるべき。SPRINT.md §1 AC-2 の検証手段は絶対パス（`/home/user/RingTest/sprint/PRODUCT.md`）で書かれており、これを正確に転記すべき。
- **観測された挙動**: 相対パスかつ `sprint/` プレフィックスが落ちている。worker は「verify_result: OK」と記録しているが、上記コマンドではその結果は出ない。worker が実際に何を実行したかが evidence から復元できない。
- **発掘時の根拠**: task-1.status.json:15-17、SPRINT.md:21（AC-2 検証手段の正しい形）。
- **Evaluator 採点との関係**: AC-2 自体は実機で正規の絶対パス版を流せば PASS（実際 PASS 採点）。ただし evidence の信頼性が損なわれており、後続の investigator / improver が evidence を頼りに再現しようとすると失敗する。

---

## F-006: AC-3 検証手段は「ちょうど 1 行」を保証していない（`grep -cx` は 1 行以上あっても 1 を返すケースを許容） [P2]

- **症状の1行サマリ**: AC-3 検証手段 `grep -cx 'ringtest-smoke-ok' smoke.txt` は「定型行と完全一致する行の数」を返すだけで、**他の余計な行が混入していても検出できない**。SPRINT.md §1 AC-3 内容欄は「定型行を **1 行だけ** 含む」と要求しており、検証手段が要件を満たさない。
- **再現手順**:
  ```bash
  # 想定: smoke.txt に "ringtest-smoke-ok" と "junk-line" が混在しても
  printf 'ringtest-smoke-ok\njunk-line\n' > /tmp/test_smoke.txt
  grep -cx 'ringtest-smoke-ok' /tmp/test_smoke.txt
  # 出力: 1  → AC-3 検証手段は PASS 判定するが、ファイルは 2 行ある
  ```
- **期待される挙動**: 「定型行を 1 行だけ含む」を厳密に検証するなら、`wc -l` でファイル全体が 1 行であることも併せて確認すべき。task-2.md §TDD 手順 §3 では正しく `wc -l` 併用を指示しているが、AC-3 検証手段（SPRINT.md §1）には反映されていない。
- **観測された挙動**: 現状は実害なし（実機の smoke.txt はちょうど 18 バイト・1 行）だが、改善ループや将来の TDD で意図しないファイル肥大化を検出できない設計。
- **発掘時の根拠**: SPRINT.md:22 (AC-3 検証手段)、SPRINT.md:22（基準内容欄 "定型行を 1 行だけ含む"）、task-2.md:46（wc -l 併用指示）。
- **Evaluator 採点との関係**: PASS への再解釈。実機状態は適合しているため採点は妥当だが、合格基準と検証手段の意味的乖離は残る。

---

## F-007: PRODUCT.md 成功条件 5（fail-closed エラー皆無）が直接検証されていない [P3]

- **症状の1行サマリ**: PRODUCT.md 成功条件 5 は「フック / サブエージェント / state 書込窓口のいずれにも fail-closed エラーが発生していない」を要求するが、SPRINT.md §1 はこれを「AC-1 の `phase=DESIGN` 到達で間接的に検証される」と D-1 / 備考で吸収しており、直接の検査手段がない。
- **再現手順**: SPRINT.md §1 備考 (25-31) と D-1 (75-82) を読む。fail-closed エラーログを直接読むコマンドが存在しないことを確認。
- **期待される挙動**: 少なくとも phase_log.jsonl にエラー痕跡が無いか・state.json の `resilience.persist_failed` や `consecutive_tool_failures` が 0 であるかを確認すべき。
- **観測された挙動**: 直接検査なし。state.json を実機で見れば `consecutive_tool_failures: 0` / `persist_failed: false` であり、現状は問題なし。
- **発掘時の根拠**: PRODUCT.md:40-42、SPRINT.md:29-31、SPRINT.md:75-82、state.json:36-41。
- **Evaluator 採点との関係**: PASS への再解釈。実機の resilience フィールドは健全だが、SPRINT.md の合格基準としては抜け落ちている。

---

## F-008: sprint/checkpoint.md が古い（CLARIFY 開始時点のまま）で、進捗の Single Source of Truth と乖離 [P3]

- **症状の1行サマリ**: `sprint/checkpoint.md` の内容が「スプリント初期化済み。次手: clarifier 起動 (CLARIFY フェーズ)」のままで、TRIAGE まで進んだ現状と乖離している。
- **再現手順**:
  ```bash
  cat /home/user/RingTest/sprint/checkpoint.md
  ```
- **期待される挙動**: フェーズ遷移ごとに更新されるか、あるいは「使わない」と明示すべき。state.json の `resume_hint.read_first` は本ファイルを参照する設計（state.json:45）であり、resume 時に誤った次手指示を読まされる懸念がある。
- **観測された挙動**: 初期メッセージのまま。
- **発掘時の根拠**: checkpoint.md:1-3、state.json:43-47。
- **Evaluator 採点との関係**: 直接の AC 対象外。盲点としての言及。

---

## F-009: sprint/DECISIONS.md が空（DESIGN フェーズで 5 個の D-* 決定をしたのに記録なし）[P3]

- **症状の1行サマリ**: `sprint/DECISIONS.md` は `# Decisions Log` のみで実体ゼロ。SPRINT.md §4 で D-1〜D-5 まで設計判断が宣言されているのに、DECISIONS.md には転記されていない。
- **再現手順**: `cat /home/user/RingTest/sprint/DECISIONS.md`
- **期待される挙動**: SPRINT.md §4 の D-1〜D-5（設計判断・理由・代替案と却下理由）が DECISIONS.md に反映されるか、あるいは SPRINT.md §4 が SoT で DECISIONS.md は使わないと明示されるべき。
- **観測された挙動**: 空のまま。
- **発掘時の根拠**: DECISIONS.md:1、SPRINT.md:71-121（5 個の D-*）。
- **Evaluator 採点との関係**: 直接の AC 対象外。文書資産の盲点。
