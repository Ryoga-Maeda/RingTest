# ClaudeRing V2 スプリントアーキテクチャ 実機テストレポート

実施日: 2026-06-17
対象: ClaudeRing V2 アーキテクチャを RingTest リポジトリへ展開し、SessionStart / PhaseAdvance フックの実走を確認

## 確認できたこと（PASS）

1. `scripts/deploy-sprint.sh --target /home/user/RingTest` がアーキ一式（`.claude/sprint`, `.claude/agents`, `.claude/commands`, `scripts/`, `tests/`）を決定論的に同期した。
2. 手動ブートストラップ（`sprint/state.json` 初期化 + `sprint/PRODUCT.md` / `SPRINT.md` / `checkpoint.md` / `DECISIONS.md` のスタブ作成）後、`tests/test_isolation.sh` が PASS=56 / FAIL=0 で M0 達成。
3. `run_state=RUNNING` に切替後、`.claude/sprint/hooks/session-start.sh` が次を実行:
   - `hook_heartbeat` を atomic に更新
   - `scripts/persona-init-v2.sh` で人格抽選（「あざとかわいいのあいり」）
   - L1 フレームワークヘッダ（R0〜R6+R3' / 9原則 / 読書ルール）を additionalContext に注入
4. PhaseAdvance フックが `scripts/phase-advance-eval.sh` を介し、CLARIFY フェーズの次手指示
   （`AskUserQuestion で CLARIFY→DESIGN 承認を求めてください`）を生成。
5. `sprint/sprint-1` ブランチには prior session の `_control_commit.sh` による自動チェックポイントコミットが既に存在。状態管理の永続化機構は機能している。

## 検出した V2 移行ギャップ（FAIL/要修正候補）

### G1: 新規ターゲットへの `sprint/state.json` ブートストラップ口が存在しない
- `scripts/deploy-sprint.sh` L300-318 は `$SOURCE/sprint/state.json` を雛形とする実装だが、ClaudeRing テンプレート本体は `sprint/state.json` を追跡していない（`git ls-tree HEAD sprint/` に存在しない）。
- v1 で初期化を担っていた `scripts/cloud-kickoff.sh` は `development/REMAINING_TASKS_PLAN.md` §3.2 PR R-2a で削除済み。「V2 ではフックと薄殻 Orchestrator が代替」と記載されているが、フック実体（`session-start.sh`）は state.json が存在することを前提に動作し、生成口が無い。
- 結果: フレッシュなターゲットでは `deploy-sprint.sh` 単独で sprint を起動できず、`tests/test_deploy_sprint.sh` シナリオ1 (`check "初回展開: sprint/state.json が存在" "yes" ...`) も再現的に失敗するはず。

### G2: `sprint/PRODUCT.md` 等のテンプレートスタブが配布されない
- `tests/test_isolation.sh` L89-95 は `sprint/PRODUCT.md`, `SPRINT.md`, `checkpoint.md`, `DECISIONS.md` の**存在**を必須としているが、これらも ClaudeRing 本体に存在しない。
- `deploy-sprint.sh` L288-291 の `scaffold_if_absent` は SOURCE 側のスタブを参照する設計で、ファイル自体が無いと no-op。

### G3: `phase-advance-eval.sh` がファイル「存在」のみで CLARIFY 完了を判定
- L129-137 で `[ ! -f sprint/PRODUCT.md ]` を判定材料にしている。スタブで初期化された PRODUCT.md と、clarifier が確定させた本物の PRODUCT.md が区別できない。
- G2 を解消するためにスタブを配布すると、clarifier 起動をスキップして CLARIFY→DESIGN 承認待ちに直接到達してしまう。

## 推奨修正方針

- ClaudeRing テンプレートに `sprint/state.json.template`（初期スキーマ）を追跡対象として追加。`deploy-sprint.sh` を `state.json.template` を雛形に変更。
- `sprint/PRODUCT.md` 等のスタブはフロントマターで「未確定」マーカーを付け、`phase-advance-eval.sh` 側で「存在 AND 未確定マーカーなし」を確定判定に変更。
- もしくは `scripts/cloud-kickoff.sh` 相当の bootstrap スクリプトを V2 ネイティブに復活させ、`/sprint-start` 起動時にユーザーが明示実行する仕組みに戻す。

## このコミットの内容

このコミットは RingTest 上で実機テストを再現するための最小限のブートストラップを保全する。
- `sprint/state.json` (v2 スキーマ・run_state=RUNNING)
- `sprint/PRODUCT.md` / `SPRINT.md` / `checkpoint.md` / `DECISIONS.md`（スタブ）
- `tests/test_isolation.sh` PASS=56 を再現可能

---

## 追補: CLARIFY → DESIGN 遷移の実機検証 (2026-06-17 追加)

### 実施フロー

1. PRODUCT.md スタブを削除 → `phase-advance-eval` が `clarifier サブエージェントを起動してください` を返すことを確認
2. Task ツールで `clarifier` を起動（goal: 「ClaudeRing V2 自律スプリント開発アーキテクチャの実機動作テスト」）
3. clarifier が `sprint/PRODUCT.md` を必須 4 セクション（目的 / 利用者像 / 成功条件 / スコープ外）で確定
4. `phase-advance-eval` 再実行 → 指示が `AskUserQuestion で CLARIFY→DESIGN 承認を求めてください` に切替
5. AskUserQuestion で Human ゲート承認を取得
6. `gate_approvals.CLARIFY_TO_DESIGN=true` を `jq + flock + atomic mv` で state.json に書込
7. `scripts/phase-advance-apply.sh` 実行 → `applied: DESIGN / implement` を出力
8. state.json: `phase=CLARIFY` → `phase=DESIGN` に遷移、`sprint/phase_log.jsonl` に遷移ログ追記

### 検証結果

| チェック | 結果 |
|---------|------|
| clarifier 起動指示が出る | ✅ |
| clarifier の Task 起動 → PRODUCT.md Write | ✅ |
| eval 再評価で AskUserQuestion ゲート指示に切替 | ✅ |
| AskUserQuestion で Human 承認取得 | ✅ |
| gate_approvals 書込 → phase-advance-apply で遷移 | ✅ |
| phase_log.jsonl に追記 | ✅ |

### 追加観測

- **clarifier の tools 配列に Bash が無いため、agent 定義の「`jq + flock + mktemp + mv` で atomic に state.json 更新」を clarifier 自身では実行不可**。今回は Orchestrator 役が代理書込した。これは V2 spec と tools 配列の整合性ズレ。
- **DESIGN 遷移直後の eval は `designer` ではなく `decomposer` を返す**。理由は G3（スタブ SPRINT.md の存在判定）。CLARIFY と同じパターンで designer が一度も起動されない経路に逸れる。
- `phase_advance_last_fired_at` は `phase-advance-apply.sh` 単体実行では更新されない（PhaseAdvance フックラッパ側の責務と思われる）。
