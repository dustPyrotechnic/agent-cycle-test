#!/usr/bin/env bash
set -euo pipefail

: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

# Trusted engine snapshot is read from ENGINE_ROOT; all git, gh, and dispatch
# operations run against the target repository checked out at TARGET_ROOT.
ENGINE_ROOT="${ENGINE_ROOT:-${WRAPPER_ROOT:-.agent}}"
TARGET_ROOT="${TARGET_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$TARGET_ROOT"

STATE_DIR=".agent_state/issues/${ISSUE_NUMBER}"
RESULT_FILE="${STATE_DIR}/result.json"
STATE_FILE="${STATE_DIR}/state.json"
AGENT_PROVIDER="${AGENT_PROVIDER:-deepseek}"

if [[ -f "${ENGINE_ROOT}/credential-leak-detected" ]]; then
  gh issue comment "$ISSUE_NUMBER" --body "Agent 周期已停止：工作树中出现了配置的模型凭据。未提交或推送任何 agent 改动。请轮换受影响的凭据，并在重试前检查失败的运行。" >/dev/null
  gh issue edit "$ISSUE_NUMBER" --add-label agent-blocked >/dev/null
  gh issue edit "$ISSUE_NUMBER" --remove-label solve-it >/dev/null 2>&1 || true
  gh issue edit "$ISSUE_NUMBER" --remove-label agent-running >/dev/null 2>&1 || true
  exit 1
fi

if [[ -f "${ENGINE_ROOT}/readonly-phase-mutation-detected" ]]; then
  gh issue comment "$ISSUE_NUMBER" --body "Agent 周期已停止：只读的分析师、验证者或复审者修改了目标工作树。未提交或推送任何 agent 改动。请在重试前检查失败的运行与角色提示词。" >/dev/null
  gh issue edit "$ISSUE_NUMBER" --add-label agent-blocked >/dev/null
  gh issue edit "$ISSUE_NUMBER" --remove-label solve-it >/dev/null 2>&1 || true
  gh issue edit "$ISSUE_NUMBER" --remove-label agent-running >/dev/null 2>&1 || true
  exit 1
fi

if [[ -f "${ENGINE_ROOT}/protected-state-mutation-detected" ]]; then
  gh issue comment "$ISSUE_NUMBER" --body "Agent 周期已停止：实施者修改了 wrapper 所有的 .agent_state/issues 内容。未提交或推送任何 agent 改动。请在重试前检查失败的运行与角色提示词。" >/dev/null
  gh issue edit "$ISSUE_NUMBER" --add-label agent-blocked >/dev/null
  gh issue edit "$ISSUE_NUMBER" --remove-label solve-it >/dev/null 2>&1 || true
  gh issue edit "$ISSUE_NUMBER" --remove-label agent-running >/dev/null 2>&1 || true
  exit 1
fi

if ! jq -e '
  (.status == "continue" or .status == "complete" or .status == "blocked")
  and (.summary | type == "string" and length > 0)
  and (.next_step | type == "string")
  and (.tests | type == "array")
  and all(.tests[]; type == "string")
  and (.findings | type == "array")
  and all(.findings[]; type == "string")
' "$RESULT_FILE" >/dev/null 2>&1; then
  jq -n '{
    status: "blocked",
    summary: "Agent 未产出符合所需 schema 的结果。",
    next_step: "检查工作流日志并修正 agent 的结果契约。",
    tests: [],
    findings: ["critical: 最终复审结果契约无效"]
  }' >"$RESULT_FILE"
fi

status="$(jq -r '.status' "$RESULT_FILE")"
summary="$(jq -r '.summary' "$RESULT_FILE")"
# Rounds that produced no code change (e.g. an evidence-insufficient fake issue
# answered by the analyst) opt out of branch and pull request publication.
# Note: jq's `//` treats both null and false as empty, so `.publish_changes //
# true` would wrongly yield true for an explicit false. Branch on the value
# instead, defaulting to publishing only when the key is absent.
publish_changes="$(jq -r 'if .publish_changes == false then "false" else "true" end' "$RESULT_FILE")"
round="$(jq -r '.round' "$STATE_FILE")"
max_rounds="$(jq -r '.max_rounds' "$STATE_FILE")"
branch="agent/issue-${ISSUE_NUMBER}"
default_branch="$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.default_branch')"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-unknown}"

if [[ "$status" == "continue" && "$round" -ge "$max_rounds" ]]; then
  status="blocked"
  summary="${summary} 已达到配置的 ${max_rounds} 轮上限。"
  jq \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg next_step "请审查该 pull request，决定如何继续后再重新添加 solve-it 标签。" \
    '.status = $status | .summary = $summary | .next_step = $next_step' \
    "$RESULT_FILE" >"${RESULT_FILE}.tmp"
  mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi

jq \
  --arg status "$status" \
  --arg summary "$summary" \
  --arg now "$now" \
  --arg run_url "$run_url" \
  '.status = $status
   | .last_summary = $summary
   | .updated_at = $now
   | .last_run_url = $run_url' \
  "$STATE_FILE" >"${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"

if [[ ! -s "${STATE_DIR}/handoff.md" ]]; then
  printf '# Handoff\n\n%s\n' "$summary" >"${STATE_DIR}/handoff.md"
fi

set +e
validation_output="$(TARGET_ROOT="$TARGET_ROOT" bash "${ENGINE_ROOT}/scripts/validate-target.sh" 2>&1)"
validation_status=$?
set -e
printf '%s\n' "$validation_output"

if [[ "$validation_status" -ne 0 ]]; then
  status="blocked"
  summary="${summary} 目标仓库校验失败。"
  jq \
    --arg summary "$summary" \
    '.status = "blocked"
     | .summary = $summary
     | .next_step = "检查并修复目标仓库的校验失败。"
     | .tests += ["validate-target.sh: failed"]
     | .findings += ["critical: 目标仓库静态校验失败"]' \
    "$RESULT_FILE" >"${RESULT_FILE}.tmp"
  mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  jq \
    --arg status "$status" \
    --arg summary "$summary" \
    '.status = $status | .last_summary = $summary' \
    "$STATE_FILE" >"${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

pr_body=""
comment_file=""
trap 'rm -f "$pr_body" "$comment_file"' EXIT

if [[ "$publish_changes" == "true" ]]; then
  git add -A

  if ! git diff --cached --quiet; then
    git commit -m "agent: issue #${ISSUE_NUMBER} round ${round} (${status})"
  fi
  git push --set-upstream origin "$branch"

  pr_url="$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty')"
  if [[ -z "$pr_url" ]]; then
    pr_body="$(mktemp)"
    cat >"$pr_body" <<EOF
针对 issue #${ISSUE_NUMBER} 的自动化有界 agent 周期。

当前状态：**${status}**
当前轮次：**${round}/${max_rounds}**

最新摘要：

${summary}

Closes #${ISSUE_NUMBER}
EOF
    pr_url="$(gh pr create \
      --base "$default_branch" \
      --head "$branch" \
      --title "agent: resolve #${ISSUE_NUMBER}" \
      --body-file "$pr_body")"
  fi
else
  pr_url="未创建（无效 issue，未产生代码改动）"
fi

comment_file="$(mktemp)"
tests="$(jq -r 'if (.tests | length) == 0 then "- 未报告" else .tests[] | "- " + . end' "$RESULT_FILE")"
findings="$(jq -r 'if (.findings | length) == 0 then "- 无" else .findings[] | "- " + . end' "$RESULT_FILE")"
next_step="$(jq -r '.next_step' "$RESULT_FILE")"
cat >"$comment_file" <<EOF
Agent 周期第 **${round}/${max_rounds}** 轮结束，状态：**${status}**。

${summary}

测试：
${tests}

发现：
${findings}

下一步：${next_step}

Pull request：${pr_url}
运行：${run_url}
EOF
gh issue comment "$ISSUE_NUMBER" --body-file "$comment_file" >/dev/null

case "$status" in
  complete)
    gh issue edit "$ISSUE_NUMBER" --add-label agent-done >/dev/null
    gh issue edit "$ISSUE_NUMBER" --remove-label solve-it >/dev/null 2>&1 || true
    gh issue edit "$ISSUE_NUMBER" --remove-label agent-running >/dev/null 2>&1 || true
    ;;
  blocked)
    gh issue edit "$ISSUE_NUMBER" --add-label agent-blocked >/dev/null
    gh issue edit "$ISSUE_NUMBER" --remove-label solve-it >/dev/null 2>&1 || true
    gh issue edit "$ISSUE_NUMBER" --remove-label agent-running >/dev/null 2>&1 || true
    ;;
  continue)
    gh api "repos/${GITHUB_REPOSITORY}/dispatches" \
      -f event_type=agent-relay \
      -F "client_payload[issue_number]=${ISSUE_NUMBER}" \
      -F "client_payload[max_rounds]=${max_rounds}" \
      -f "client_payload[provider]=${AGENT_PROVIDER}"
    ;;
esac

echo "Finalized issue #${ISSUE_NUMBER} round ${round}: ${status}"
