# L2: 実行層 共通プリ

## 共通責務
- 1 タスク単位の責務に集中する
- 出力は state.json と task worktree 内のファイルに限定

## 共通禁止事項
- 他タスクの worktree に書き込まない
- 親（executor）の指示外の操作を行わない
