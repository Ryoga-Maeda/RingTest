#!/usr/bin/env bash
# R6 強制フック: worker/executor/phase エージェント等が Bash で
# git / git worktree / gh を直接実行することを deny する。
# 入力: stdin に {"tool_name":"Bash","tool_input":{"command":"..."},"subagent_type":"...",...}
# 出力: PreToolUse permissionDecision を含む hookSpecificOutput JSON
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
agent=$(echo "$input" | jq -r '.subagent_type // .agent // empty')

R6_TARGETS="worker executor clarifier designer decomposer verifier integrator completer generator reviewer evaluator bug-hunter investigator orchestrator-v2"

target=false
for a in $R6_TARGETS; do
  if [ "$agent" = "$a" ]; then
    target=true
    break
  fi
done

if [ "$target" = "true" ] && echo "$cmd" | grep -Eq '(^|[;&|]\s*)(sudo\s+)?(git|gh)(\s|$)|git\s+worktree'; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "R6 違反: git / gh は repo-mgr / worktree-mgr 経由で実行してください（直接実行禁止）"
    }
  }'
  exit 0
fi

jq -nc '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow"
  }
}'
