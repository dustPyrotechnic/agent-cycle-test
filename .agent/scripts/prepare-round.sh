#!/usr/bin/env bash
set -euo pipefail

: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

# Trusted engine scripts/prompts are read from ENGINE_ROOT; every git and gh
# operation runs against the target repository checked out at TARGET_ROOT.
ENGINE_ROOT="${ENGINE_ROOT:-${WRAPPER_ROOT:-.agent}}"
TARGET_ROOT="${TARGET_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$TARGET_ROOT"

if [[ ! "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ISSUE_NUMBER must be numeric" >&2
  exit 1
fi

MAX_ROUNDS="${MAX_ROUNDS:-5}"
AGENT_PROVIDER="${AGENT_PROVIDER:-deepseek}"
TRUSTED_ASSOCIATIONS="${TRUSTED_ASSOCIATIONS:-OWNER}"
STATE_DIR=".agent_state/issues/${ISSUE_NUMBER}"
ISSUE_JSON="$(mktemp)"
trap 'rm -f "$ISSUE_JSON"' EXIT

if [[ ! "$MAX_ROUNDS" =~ ^[0-9]+$ ]] || ((MAX_ROUNDS < 1 || MAX_ROUNDS > 20)); then
  echo "MAX_ROUNDS must be an integer between 1 and 20" >&2
  exit 1
fi

gh api "repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}" >"$ISSUE_JSON"

if jq -e '.pull_request != null' "$ISSUE_JSON" >/dev/null; then
  echo "Issue #${ISSUE_NUMBER} is a pull request, not an issue" >&2
  exit 1
fi

association="$(jq -r '.author_association' "$ISSUE_JSON")"
case ",${TRUSTED_ASSOCIATIONS}," in
  *",${association},"*) ;;
  *)
    echo "Issue #${ISSUE_NUMBER} is not authored by a trusted collaborator (${association})" >&2
    exit 1
    ;;
esac

# Every issue is eligible once it clears the trust gate; no opt-in label is
# required. The listener triggers on opened/reopened/edited (and an optional
# solve-it label), so the cycle recognizes all issues, not a special class.

default_branch="$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.default_branch')"
branch="agent/issue-${ISSUE_NUMBER}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git fetch origin "$default_branch"

if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  git fetch origin "$branch"
  git checkout -B "$branch" "origin/$branch"
else
  git checkout -B "$branch" "origin/$default_branch"
fi

mkdir -p "$STATE_DIR"

if [[ -f "${STATE_DIR}/state.json" ]]; then
  current_round="$(jq -r '.round // 0' "${STATE_DIR}/state.json")"
else
  current_round=0
fi

next_round=$((current_round + 1))
if ((next_round > MAX_ROUNDS)); then
  echo "Issue #${ISSUE_NUMBER} has reached the ${MAX_ROUNDS}-round limit" >&2
  exit 1
fi

jq -r '
  "# Issue #\(.number): \(.title)\n\n" +
  "- URL: \(.html_url)\n" +
  "- Author association: \(.author_association)\n" +
  "- Labels: " + ([.labels[].name] | join(", ")) + "\n\n" +
  "## Body\n\n" + (.body // "(empty)")
' "$ISSUE_JSON" >"${STATE_DIR}/issue.md"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -f "${STATE_DIR}/state.json" ]]; then
  jq \
    --argjson round "$next_round" \
    --argjson max_rounds "$MAX_ROUNDS" \
    --arg provider "$AGENT_PROVIDER" \
    --arg now "$now" \
    '.round = $round
     | .max_rounds = $max_rounds
     | .provider = $provider
     | .status = "running"
     | .updated_at = $now' \
    "${STATE_DIR}/state.json" >"${STATE_DIR}/state.json.tmp"
else
  jq -n \
    --argjson issue "$ISSUE_NUMBER" \
    --argjson round "$next_round" \
    --argjson max_rounds "$MAX_ROUNDS" \
    --arg provider "$AGENT_PROVIDER" \
    --arg now "$now" \
    '{
      issue: $issue,
      round: $round,
      max_rounds: $max_rounds,
      provider: $provider,
      status: "running",
      created_at: $now,
      updated_at: $now
    }' >"${STATE_DIR}/state.json.tmp"
fi
mv "${STATE_DIR}/state.json.tmp" "${STATE_DIR}/state.json"
rm -f "${STATE_DIR}/result.json"

gh label create agent-running --color 1d76db --description "Agent cycle is running" --force
gh label create agent-done --color 0e8a16 --description "Agent cycle completed; review the pull request" --force
gh label create agent-blocked --color b60205 --description "Agent cycle needs maintainer input" --force
gh issue edit "$ISSUE_NUMBER" --add-label agent-running >/dev/null
gh issue edit "$ISSUE_NUMBER" --remove-label agent-blocked >/dev/null 2>&1 || true
gh issue edit "$ISSUE_NUMBER" --remove-label agent-done >/dev/null 2>&1 || true

git add "$STATE_DIR"
if ! git diff --cached --quiet; then
  git commit -m "chore(agent): start issue #${ISSUE_NUMBER} round ${next_round}"
  git push --set-upstream origin "$branch"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "branch=${branch}"
    echo "default_branch=${default_branch}"
    echo "round=${next_round}"
    echo "state_dir=${STATE_DIR}"
  } >>"$GITHUB_OUTPUT"
fi

echo "Prepared issue #${ISSUE_NUMBER}, round ${next_round}/${MAX_ROUNDS}, on ${branch}"
