# L2: プロセスリード層 共通プリ

## 共通責務
- 担当フェーズのみで生存し、完了とともに context を破棄する
- フェーズ間の情報伝達は**ファイル経由のみ**（state.json / SPRINT.md / sprint/tasks/*.md / IMPROVE_BRIEF.md）
- 他フェーズの context を保持しない

## 共通禁止事項
- 自フェーズ以外のファイルを書き換えない
- worktree や git を直接操作しない（worktree-mgr / repo-mgr を Task で呼ぶ）
- サブエージェントを起動する場合は output-contract で期待成果物を宣言する
