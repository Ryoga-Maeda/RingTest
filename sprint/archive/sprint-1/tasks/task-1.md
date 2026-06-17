# task-1: AC-2 整合性確認タスク（PRODUCT.md / SPRINT.md 必須見出し検査）

## 目的

PRODUCT.md と SPRINT.md の両方が存在し、それぞれの必須見出しを含むことを
worker フェーズで確認・確定する。SPRINT.md §1 の AC-2 を満たすための実装タスク。

合格基準 AC-2 の検証コマンドは次のとおり（evaluator フェーズで実行される）。

```bash
test -s /home/user/RingTest/sprint/PRODUCT.md \
  && test -s /home/user/RingTest/sprint/SPRINT.md \
  && grep -q '^## スコープ外' /home/user/RingTest/sprint/PRODUCT.md \
  && grep -q '^## 1\. 合格基準表' /home/user/RingTest/sprint/SPRINT.md \
  && echo OK
```

期待結果は標準出力 `OK` の単一行・終了コード 0。

## 入力

- `/home/user/RingTest/sprint/PRODUCT.md`（CLARIFY 成果物・凍結済み・INV-5）
- `/home/user/RingTest/sprint/SPRINT.md`（DESIGN 成果物・本タスク開始時点で既存）

## 出力

- なし（読取のみ）。本タスクは「ファイルが既に必須条件を満たしている」ことを worker が
  自前のテストコマンドで確認し、status を COMPLETE にする確認系タスク。
- もし必須見出しが欠落していた場合は SPRINT.md を編集して見出しを補う（INV-5 により
  PRODUCT.md は編集禁止のため、欠落していたら ESCALATION）。

## TDD 手順（worker 向け）

1. **RED**: 次のコマンドを実行し、終了コード 0 で `OK` が返ることをテストする。

   ```bash
   test -s /home/user/RingTest/sprint/PRODUCT.md \
     && test -s /home/user/RingTest/sprint/SPRINT.md \
     && grep -q '^## スコープ外' /home/user/RingTest/sprint/PRODUCT.md \
     && grep -q '^## 1\. 合格基準表' /home/user/RingTest/sprint/SPRINT.md \
     && echo OK
   ```

2. **GREEN**: 上記が通れば、追加実装不要。status.json を COMPLETE に遷移し、
   `evidence` フィールドに上記コマンドの実行結果を記録する。
3. 通らなかった場合:
   - PRODUCT.md 側欠落 → INV-5 違反になるため作業を止めて ESCALATION（R5 相当）。
   - SPRINT.md 側欠落 → SPRINT.md を編集して `## 1. 合格基準表` 見出しを補う。

## 依存関係

- depends_on: なし
- touches: `sprint/SPRINT.md`（編集される可能性のみ・通常は読取のみ）

## 不変条件

- INV-5: PRODUCT.md は編集しない
- INV-3: state.json には直接書き込まない
- INV-6: 生成物は `sprint/artifacts/` 配下のみ（本タスクは生成物なし）

## 完了条件

1. 上記検証コマンドが終了コード 0 で `OK` を出力
2. status.json が COMPLETE
3. evidence に検証コマンドの実行結果が記録されている
