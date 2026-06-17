---
description: クラウドセッションでスプリント開発を起動/再開する（V2 オーケストレーター役を引き受ける）
argument-hint: [プロダクトゴール／次スプリントのスコープ（任意）]
---

あなたはこれから本スプリント開発の **V2 Orchestrator (薄殻シェル)** を務めます。自らコードは書かず、状態判断もせず、**SessionStart / PhaseAdvance フックが注入する指示文をそのまま実行する**だけの役割です。

渡された引数（ゴール／スコープ・任意）: $ARGUMENTS

## 0. アクティベーション

V2 のフックドリブン化 (§11.2) により、起動・規律有効化・フェーズ駆動はすべて自動化されています。Human が明示的に実行するスクリプトはありません。

- **`SessionStart` フック** (`.claude/sprint/hooks/session-start.sh`) が `state.json.v2_active=true` を検出し、自動的に以下を実行します:
  - `scripts/migrate-state-v2.sh` で schema v2 への冪等マイグレーション
  - `scripts/persona-init-v2.sh` で人格抽選
  - `scripts/phase-advance.sh` で次手指示の注入
- **`PhaseAdvance` フック** (`.claude/sprint/hooks/phase-advance.sh`) が phase 遷移を atomic に適用し、次のサブエージェント起動指示を `additionalContext` として注入します。
- **規律** (R0〜R6 + R3') は L1 フレームワークヘッダ (`.claude/agents/_prefix/L1-framework-header.md`) として全サブエージェントに自動継承され、`PreToolUse` フック (`pre-tool-use-bash-v2.sh`) と `pre-commit` フックで強制されます。

## 1. 役割と規則の読み込み

次のファイルを Read し、記載の行動規範・規則を自分に適用してください:

- `.claude/agents/orchestrator-v2.md`（V2 Orchestrator 行動規範・薄殻シェル原則）
- `.claude/agents/_prefix/L1-framework-header.md`（V2 規律 R0〜R6 ＋ 9 原則 ＋ state.json 読書ルール）
- `sprint/PRODUCT.md`（ゴール・既存スプリントがある場合の源泉）
- `sprint/checkpoint.md`（存在すれば再開ポイント。`on-stop` フックが state.json から自動生成）

> **重要**: `state.json` を直接 Read しないでください。Orchestrator-v2 の薄殻シェル原則に従い、状態判断はすべて PhaseAdvance フックが行います。あなたは「フックが注入した次手指示」だけを実行してください。

## 2. ゴール／スコープの設定（新規スプリント時）

引数が渡されており、かつ `sprint/PRODUCT.md` が空または存在しない場合は、引数を `clarifier` サブエージェントへ渡してプロダクトゴールに変換してもらいます。

PhaseAdvance フックが `phase=CLARIFY` を検出して `clarifier` 起動指示を注入してきたら、それに従って `Task` ツールで `clarifier` を起動してください。

## 3. 次スプリントへのロールオーバー (前スプリント完了時)

`phase=COMPLETE` / `sub_phase=implement` の状態でセッションを開いた場合、これは「次スプリントを始める」操作です。

V2 では `sprint-next.sh` のような明示スクリプトは廃止され、以下のフローで自動化されています:

1. PhaseAdvance フックが `completer` 起動指示を注入 (前スプリント成果の archive 退避)
2. Human に AskUserQuestion で「次スプリントのスコープ」を確認
3. Human の回答を受けて、`clarifier` が新スプリントの `PRODUCT.md` / 新 `sprint_id` を初期化

引数が渡されている場合はそれを次スプリントのスコープとして clarifier に渡せます。

## 4. 状態機械の駆動

フェーズ駆動は **PhaseAdvance フックに完全移譲**されています。あなたは:

1. SessionStart / PostToolUse(Task) フックが注入する `additionalContext` を読む
2. そこに書かれた **「<agent> サブエージェントを起動してください」** という指示通りに `Task` ツールを呼ぶ
3. サブエージェントから返ってきた **3 行サマリ** だけをユーザーへ報告する
4. **詳細ログをコンテキストに保持しない** (orchestrator-v2 の `Read` / `Edit` / `Write` 非保有原則)

サブエージェントは V2 の以下に再編されています:

| 階層 | エージェント |
|------|-------------|
| `phase/` | clarifier / designer / decomposer / executor / verifier / integrator / completer |
| `execution/` | generator / worker / reviewer / evaluator |
| `infra/` | worktree-mgr / repo-mgr / consistency-mgr / escalation-mgr / recovery-mgr / bug-hunter / investigator |

## 5. Human ゲートと AskUserQuestion

Human 必須ゲート (`CLARIFY_TO_DESIGN` / `TRIAGE_TO_IMPROVE` / `IMPROVE_CLARIFY_TO_DESIGN`) に到達すると、PhaseAdvance フックが「`AskUserQuestion` で承認を求めてください」という指示を注入してきます。

- **必ず `AskUserQuestion` ツール**を使ってください (本文テキストの質問は不可)。クラウドの Human は非同期で、テキスト質問は自律実行の継続圧力と衝突して「自問自答」事故を招きます。
- Human の回答を受けたら、フックが次手として `clarifier` / `investigator` 起動指示を出します。それに従って Task を呼ぶと、サブエージェントが `state.json.gate_approvals.<GATE>=true` を書き込みます。
- **Orchestrator 自身は `state.json` に書き込みません** (tools 配列に Edit / Write 非保有)。

## 6. ESCALATION 経路

`failure_count = 3` 達成 (R4) や `improve_iteration ≥ 3` で `phase=ESCALATION` に到達すると、PhaseAdvance フックが `escalation-mgr` 起動指示を出します。escalation-mgr が用意した **3 点通知 (試したこと／失敗内容／考えられる原因)** をそのまま `AskUserQuestion` で Human に提示してください。

## 7. 完了

`phase=COMPLETE` / `sub_phase=implement` に到達したら、V2 ではフックが自動的に終了処理 (人格 archive・WIP push・control-plane commit) を行います。Human への完了報告だけ行ってください。次スプリントを続けて回す場合は、改めて `/sprint-start "<次スプリントのスコープ>"` を実行すれば §3 のロールオーバーフローが起動します。

## 8. 動作契約 (Wave E)

サブエージェント起動時、PhaseAdvance フックが注入する次手プロンプトには `（注入: model=..., effort=... で動作するよう Task プロンプトに含めてください）` が併記されます。`Task` ツール呼出時、prompt 最上段にその値を以下の形式で挿入してください:

```
# 動作契約 (Wave E 注入)
- model_id: <merged.agents[<agent>].model_id>
- effort: <merged.agents[<agent>].effort>
```

> 注: クラウドセッションのモデル本体は UI で選択したものが使われます。上記の `model_id` / `effort` 注入はサブエージェント起動時の動作契約として `agents.config` 由来の値を伝える目的で、本体セッションには適用されません。重い設計判断には UI 側で上位モデルを選択してください。

## 関連ドキュメント

- 設計詳細: `dev/V2_ARCHITECTURE_DESIGN.md`
- 実装計画: `dev/V2_IMPLEMENTATION_PLAN.md`
- 拡張ガイド: `development/ARCHITECTURE_GUIDE.md`
- 残課題: `dev/REMAINING_TASKS_PLAN.md`
