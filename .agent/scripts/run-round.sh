#!/usr/bin/env bash
set -euo pipefail

: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"

STATE_DIR=".agent_state/issues/${ISSUE_NUMBER}"
AGENT_PROVIDER="${AGENT_PROVIDER:-deepseek}"
AGENT_TIMEOUT_MINUTES="${AGENT_TIMEOUT_MINUTES:-35}"
PROMPT_TEMPLATE="${WRAPPER_ROOT:-.agent}/prompts/agent-round.md"
PROMPT_FILE="$(mktemp)"
OUTPUT_FILE="$(mktemp)"
CLAUDE_HOME="$(mktemp -d)"
trap 'rm -rf "$PROMPT_FILE" "$OUTPUT_FILE" "$CLAUDE_HOME"' EXIT

mask_value() {
  local value="$1"
  if [[ -n "$value" ]]; then
    echo "::add-mask::${value}"
  fi
}

mask_value "${DEEPSEEK_API_KEY:-}"
mask_value "${MIMO_API_KEY:-}"
mask_value "${MY_AGENT_PAT:-}"

case "$AGENT_PROVIDER" in
  deepseek)
    : "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY is not available as an Actions secret}"
    export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
    export ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY"
    export ANTHROPIC_MODEL="deepseek-v4-pro[1m]"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_MODEL"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$ANTHROPIC_MODEL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
    export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
    unset DEEPSEEK_API_KEY
    unset MIMO_API_KEY
    ;;
  mimo)
    : "${MIMO_API_KEY:?MIMO_API_KEY is not available as an Actions secret}"
    export ANTHROPIC_BASE_URL="https://api.xiaomimimo.com/anthropic"
    export ANTHROPIC_AUTH_TOKEN="$MIMO_API_KEY"
    export ANTHROPIC_MODEL="mimo-v2.5-pro"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_MODEL"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$ANTHROPIC_MODEL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$ANTHROPIC_MODEL"
    unset DEEPSEEK_API_KEY
    unset MIMO_API_KEY
    ;;
  *)
    echo "Unsupported provider: ${AGENT_PROVIDER}" >&2
    exit 1
    ;;
esac

export CLAUDE_CODE_EFFORT_LEVEL="max"
mask_value "$ANTHROPIC_AUTH_TOKEN"

cat "$PROMPT_TEMPLATE" >"$PROMPT_FILE"
cat >>"$PROMPT_FILE" <<EOF

## Current Round

- Issue number: ${ISSUE_NUMBER}
- Issue snapshot: ${STATE_DIR}/issue.md
- Lifecycle state: ${STATE_DIR}/state.json
- Previous handoff: ${STATE_DIR}/handoff.md
- Required result: ${STATE_DIR}/result.json
- Required handoff: ${STATE_DIR}/handoff.md
EOF

set +e
env -i \
  HOME="$CLAUDE_HOME" \
  PATH="$PATH" \
  LANG="${LANG:-C.UTF-8}" \
  SHELL="/bin/bash" \
  TMPDIR="${TMPDIR:-/tmp}" \
  CI="true" \
  ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
  ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN" \
  ANTHROPIC_MODEL="$ANTHROPIC_MODEL" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$ANTHROPIC_DEFAULT_SONNET_MODEL" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$ANTHROPIC_DEFAULT_HAIKU_MODEL" \
  CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-$ANTHROPIC_MODEL}" \
  CLAUDE_CODE_EFFORT_LEVEL="$CLAUDE_CODE_EFFORT_LEVEL" \
  timeout "${AGENT_TIMEOUT_MINUTES}m" \
  claude \
    --print \
    --permission-mode bypassPermissions \
    --no-session-persistence \
    --effort max \
    --model "$ANTHROPIC_MODEL" \
    <"$PROMPT_FILE" | tee "$OUTPUT_FILE"
claude_status="${PIPESTATUS[0]}"
set -e

leak_sentinel="${WRAPPER_ROOT:-.agent}/credential-leak-detected"
if git grep --untracked --exclude-standard -I -F -q -- "$ANTHROPIC_AUTH_TOKEN"; then
  touch "$leak_sentinel"
  jq -n '{
    status: "blocked",
    summary: "A configured model credential appeared in the working tree, so no changes were published.",
    next_step: "Rotate the affected credential and inspect the failed run before retrying.",
    tests: []
  }' >"${STATE_DIR}/result.json"
fi
unset ANTHROPIC_AUTH_TOKEN

if [[ ! -s "${STATE_DIR}/result.json" ]]; then
  mkdir -p "$STATE_DIR"
  if [[ "$claude_status" -eq 124 ]]; then
    jq -n '{
      status: "continue",
      summary: "Claude Code reached the per-round timeout before writing result.json.",
      next_step: "Resume from the current branch and inspect the working tree before continuing.",
      tests: []
    }' >"${STATE_DIR}/result.json"
  else
    jq -n \
      --arg status "$claude_status" \
      '{
        status: "blocked",
        summary: ("Claude Code exited without a valid result.json (exit " + $status + ")."),
        next_step: "Inspect the workflow log and fix the runtime or prompt contract.",
        tests: []
      }' >"${STATE_DIR}/result.json"
  fi
fi

exit 0
