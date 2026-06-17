# task-2: AC-3 スモークマーカー生成タスク

## 目的

SPRINT.md §1 の AC-3 を満たすため、`sprint/artifacts/smoke.txt` に定型行
`ringtest-smoke-ok` をちょうど 1 行だけ書く。実装系の最小疎通（worker / worktree-mgr /
evaluator の経路が機能していること）を検証するためのスモーク。

合格基準 AC-3 の検証コマンドは次のとおり（evaluator フェーズで実行される）。

```bash
test -f /home/user/RingTest/sprint/artifacts/smoke.txt \
  && grep -cx 'ringtest-smoke-ok' /home/user/RingTest/sprint/artifacts/smoke.txt
```

期待結果は標準出力 `1`・終了コード 0（`ringtest-smoke-ok` 行がちょうど 1 行）。

## 入力

- なし（新規生成）

## 出力

- `/home/user/RingTest/sprint/artifacts/smoke.txt`
  - 内容: `ringtest-smoke-ok` のみ（改行終端 1 行）
  - 揮発値（タイムスタンプ・乱数・session id）を含めない（D-4）

## TDD 手順（worker 向け）

1. **RED**: 次のテストコマンドを実行し、初回は失敗することを確認する。

   ```bash
   test -f /home/user/RingTest/sprint/artifacts/smoke.txt \
     && [ "$(grep -cx 'ringtest-smoke-ok' /home/user/RingTest/sprint/artifacts/smoke.txt)" = "1" ]
   ```

   ファイルがまだ存在しないので終了コードは非ゼロになるはず。これが RED。

2. **GREEN**: ディレクトリと定型行ファイルを生成する。

   ```bash
   mkdir -p /home/user/RingTest/sprint/artifacts
   printf 'ringtest-smoke-ok\n' > /home/user/RingTest/sprint/artifacts/smoke.txt
   ```

3. **検証**: 上記 RED のコマンドが終了コード 0 で `1` を返すことを確認。
   `wc -l` で 1 行であることも併せて確認。
4. status.json を COMPLETE に遷移し、`evidence` に
   `grep -cx 'ringtest-smoke-ok' .../smoke.txt` の結果を記録する。

## 依存関係

- depends_on: なし
- touches: `sprint/artifacts/smoke.txt`

## 不変条件

- INV-6: 成果物は `sprint/artifacts/` 配下に限定する
- INV-3: state.json には書き込まない
- D-4: 定型行は `ringtest-smoke-ok` 固定（揮発値禁止）

## 完了条件

1. `sprint/artifacts/smoke.txt` が存在
2. `grep -cx 'ringtest-smoke-ok' .../smoke.txt` が `1` を出力
3. ファイル行数が 1 行（`wc -l` が 1）
4. status.json が COMPLETE で evidence 記録あり
