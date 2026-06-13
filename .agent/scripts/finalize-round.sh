#!/usr/bin/env bash
set -euo pipefail

: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

STATE_DIR=".agent_state/issues/${ISSUE_NUMBER}"
RESULT_FILE="${STATE_DIR}/result.json"
STATE_FILE="${STATE_DIR}/state.json"
AGENT_PROVIDER="${AGENT_PROVIDER:-deepseek}"

if [[ -f "${WRAPPER_ROOT:-.agent}/credential-leak-detected" ]]; then
  gh issue comment "$ISSUE_NUMBER" --body "The agent cycle stopped because a configured model credential appeared in the working tree. No agent changes were committed or pushed. Rotate the affected credential and inspect the failed run before retrying." >/dev/null
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
' "$RESULT_FILE" >/dev/null 2>&1; then
  jq -n '{
    status: "blocked",
    summary: "The agent did not produce a result matching the required schema.",
    next_step: "Inspect the workflow log and correct the agent result contract.",
    tests: []
  }' >"$RESULT_FILE"
fi

status="$(jq -r '.status' "$RESULT_FILE")"
summary="$(jq -r '.summary' "$RESULT_FILE")"
round="$(jq -r '.round' "$STATE_FILE")"
max_rounds="$(jq -r '.max_rounds' "$STATE_FILE")"
branch="agent/issue-${ISSUE_NUMBER}"
default_branch="$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.default_branch')"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-unknown}"

if [[ "$status" == "continue" && "$round" -ge "$max_rounds" ]]; then
  status="blocked"
  summary="${summary} The configured ${max_rounds}-round limit has been reached."
  jq \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg next_step "Review the pull request and re-add solve-it only after deciding how to continue." \
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
validation_output="$("${WRAPPER_ROOT:-.agent}/scripts/validate.sh" 2>&1)"
validation_status=$?
set -e
printf '%s\n' "$validation_output"

if [[ "$validation_status" -ne 0 ]]; then
  status="blocked"
  summary="${summary} Repository agent configuration validation failed."
  jq \
    --arg summary "$summary" \
    '.status = "blocked"
     | .summary = $summary
     | .next_step = "Inspect and fix the repository agent configuration validation failure."
     | .tests += ["bash .agent/scripts/validate.sh: failed"]' \
    "$RESULT_FILE" >"${RESULT_FILE}.tmp"
  mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  jq \
    --arg status "$status" \
    --arg summary "$summary" \
    '.status = $status | .last_summary = $summary' \
    "$STATE_FILE" >"${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

git add -A

if ! git diff --cached --quiet; then
  git commit -m "agent: issue #${ISSUE_NUMBER} round ${round} (${status})"
fi
git push --set-upstream origin "$branch"

pr_url="$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty')"
if [[ -z "$pr_url" ]]; then
  pr_body="$(mktemp)"
  trap 'rm -f "$pr_body"' EXIT
  cat >"$pr_body" <<EOF
Automated bounded agent cycle for issue #${ISSUE_NUMBER}.

Current status: **${status}**
Current round: **${round}/${max_rounds}**

Latest summary:

${summary}

Closes #${ISSUE_NUMBER}
EOF
  pr_url="$(gh pr create \
    --base "$default_branch" \
    --head "$branch" \
    --title "agent: resolve #${ISSUE_NUMBER}" \
    --body-file "$pr_body")"
fi

comment_file="$(mktemp)"
trap 'rm -f "$comment_file"' EXIT
tests="$(jq -r 'if (.tests | length) == 0 then "- Not reported" else .tests[] | "- " + . end' "$RESULT_FILE")"
next_step="$(jq -r '.next_step' "$RESULT_FILE")"
cat >"$comment_file" <<EOF
Agent cycle round **${round}/${max_rounds}** finished with status **${status}**.

${summary}

Tests:
${tests}

Next step: ${next_step}

Pull request: ${pr_url}
Run: ${run_url}
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
