#!/usr/bin/env bash
set -euo pipefail

: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"

# Trusted prompts and skills are read from ENGINE_ROOT; all four specialized
# agents operate on the target repository checked out at TARGET_ROOT.
ENGINE_ROOT="${ENGINE_ROOT:-${WRAPPER_ROOT:-.agent}}"
TARGET_ROOT="${TARGET_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$TARGET_ROOT"

STATE_DIR=".agent_state/issues/${ISSUE_NUMBER}"
ISSUE_FILE="${STATE_DIR}/issue.md"
STATE_FILE="${STATE_DIR}/state.json"
HANDOFF_FILE="${STATE_DIR}/handoff.md"
ANALYSIS_FILE="${STATE_DIR}/analysis.json"
IMPLEMENTATION_FILE="${STATE_DIR}/implementation.json"
VERIFICATION_FILE="${STATE_DIR}/verification.json"
REVIEW_FILE="${STATE_DIR}/review.json"
RESULT_FILE="${STATE_DIR}/result.json"

AGENT_PROVIDER="${AGENT_PROVIDER:-deepseek}"
ANALYSIS_TIMEOUT_MINUTES="${AGENT_ANALYSIS_TIMEOUT_MINUTES:-10}"
IMPLEMENTATION_TIMEOUT_MINUTES="${AGENT_IMPLEMENTATION_TIMEOUT_MINUTES:-${AGENT_TIMEOUT_MINUTES:-35}}"
REVIEW_TIMEOUT_MINUTES="${AGENT_REVIEW_TIMEOUT_MINUTES:-10}"
VERIFICATION_TIMEOUT_MINUTES="${AGENT_VERIFICATION_TIMEOUT_MINUTES:-10}"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

COMMON_SYSTEM="${ENGINE_ROOT}/prompts/agent-round.md"
ANALYST_SYSTEM="${ENGINE_ROOT}/prompts/analyst-system.md"
IMPLEMENTER_SYSTEM="${ENGINE_ROOT}/prompts/implementer-system.md"
VERIFIER_SYSTEM="${ENGINE_ROOT}/prompts/verifier-system.md"
REVIEWER_SYSTEM="${ENGINE_ROOT}/prompts/reviewer-system.md"

TASK_ANALYSIS_SKILL="${ENGINE_ROOT}/skills/task-analysis/SKILL.md"
DEBUGGING_SKILL="${ENGINE_ROOT}/skills/systematic-debugging/SKILL.md"
CYBER_DIVINATION_SKILL="${ENGINE_ROOT}/skills/cyber-divination-debug/SKILL.md"
TEST_DRIVEN_SKILL="${ENGINE_ROOT}/skills/test-driven-change/SKILL.md"
VERIFICATION_SKILL="${ENGINE_ROOT}/skills/regression-verification/SKILL.md"
REVIEW_SKILL="${ENGINE_ROOT}/skills/evidence-based-review/SKILL.md"

mask_value() {
  local value="$1"
  if [[ -n "$value" ]]; then
    echo "::add-mask::${value}"
  fi
}

require_file() {
  [[ -s "$1" ]] || {
    echo "Required pipeline file is missing or empty: $1" >&2
    exit 1
  }
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required runtime command is unavailable: $1" >&2
    exit 1
  }
}

normalize_agent_json() {
  # Recover a single JSON object from a raw agent transcript in place. Models
  # sometimes wrap the required JSON in a Markdown code fence or prepend
  # conversational preamble despite the contract. They also occasionally put a
  # shell-style escape such as \| inside a JSON string, which is invalid JSON.
  # Extract the object and repair only invalid backslash escapes inside strings
  # so the downstream contract check sees it. Leave the file unchanged when no
  # parseable JSON can be recovered, so other malformed output still fails.
  local file="$1"
  local normalized="${file}.normalized"
  local repaired="${file}.repaired"

  if jq -e . "$file" >/dev/null 2>&1; then
    return 0
  fi

  if awk '
    /^[[:space:]]*```/ { fence++; next }
    fence == 1 { print }
    fence >= 2 { exit }
  ' "$file" >"$normalized" && normalize_json_candidate "$normalized" "$repaired"; then
    mv "$repaired" "$file"
    rm -f "$normalized"
    return 0
  fi

  if awk '
    { lines[NR] = $0 }
    END {
      first = 0
      last = 0
      for (i = 1; i <= NR; i++) if (first == 0 && index(lines[i], "{")) first = i
      for (i = NR; i >= 1; i--) if (last == 0 && index(lines[i], "}")) last = i
      if (first && last >= first) for (i = first; i <= last; i++) print lines[i]
    }
  ' "$file" >"$normalized" && normalize_json_candidate "$normalized" "$repaired"; then
    mv "$repaired" "$file"
    rm -f "$normalized"
    return 0
  fi

  rm -f "$normalized" "$repaired"
  return 0
}

normalize_json_candidate() {
  local candidate="$1"
  local repaired="$2"

  [[ -s "$candidate" ]] || return 1
  if jq -e . "$candidate" >/dev/null 2>&1; then
    cp "$candidate" "$repaired"
    return 0
  fi

  awk '
    {
      output = ""
      in_string = 0
      escaped = 0
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (!in_string) {
          output = output char
          if (char == "\"") in_string = 1
          continue
        }
        if (escaped) {
          output = output char
          escaped = 0
          continue
        }
        if (char == "\\") {
          next_char = substr($0, i + 1, 1)
          if (index("\"\\/bfnrtu", next_char) == 0) output = output "\\"
          output = output char
          escaped = 1
          continue
        }
        output = output char
        if (char == "\"") in_string = 0
      }
      print output
    }
  ' "$candidate" >"$repaired"

  jq -e . "$repaired" >/dev/null 2>&1
}

build_system_prompt() {
  local destination="$1"
  shift
  : >"$destination"
  for source in "$@"; do
    require_file "$source"
    {
      cat "$source"
      printf '\n\n'
    } >>"$destination"
  done
}

run_agent() {
  local phase="$1"
  local permission_mode="$2"
  local timeout_minutes="$3"
  local system_prompt="$4"
  local task_prompt="$5"
  local output_file="$6"
  local agent_status=0
  local workflow_command_token=""
  local -a permission_args=()

  case "$permission_mode" in
    readonly)
      permission_args=(
        --permission-mode bypassPermissions
        --tools "Bash,Read,Glob,Grep"
        --disallowedTools "Edit,Write,NotebookEdit"
      )
      ;;
    bypassPermissions)
      permission_args=(--permission-mode bypassPermissions)
      ;;
    *)
      echo "Unsupported phase permission mode: ${permission_mode}" >&2
      return 2
      ;;
  esac

  echo "Starting ${phase} agent"
  workflow_command_token="agent-cycle-${phase}-${RANDOM}-${RANDOM}-${RANDOM}"
  printf '::stop-commands::%s\n' "$workflow_command_token"
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
    timeout "${timeout_minutes}m" \
    claude \
      --print \
      --bare \
      --disable-slash-commands \
      "${permission_args[@]}" \
      --no-session-persistence \
      --effort max \
      --model "$ANTHROPIC_MODEL" \
      --append-system-prompt "$(cat "$system_prompt")" \
      <"$task_prompt" | tee "$output_file"
  agent_status="${PIPESTATUS[0]}"
  printf '::%s::\n' "$workflow_command_token"
  return "$agent_status"
}

working_tree_fingerprint() {
  {
    git diff --binary --no-ext-diff HEAD
    git status --porcelain=v1 --untracked-files=all
    while IFS= read -r -d '' file; do
      printf '%s ' "$file"
      git hash-object -- "$file"
    done < <(git ls-files --others --exclude-standard -z)
  } | git hash-object --stdin
}

state_tree_fingerprint() {
  local protected_path=".agent_state/issues"

  {
    git diff --binary --no-ext-diff HEAD -- "$protected_path"
    git status --porcelain=v1 --untracked-files=all -- "$protected_path"
    while IFS= read -r -d '' file; do
      printf '%s ' "$file"
      git hash-object -- "$file"
    done < <(git ls-files --others --exclude-standard -z -- "$protected_path")
  } | git hash-object --stdin
}

run_readonly_agent() {
  local phase="$1"
  local timeout_minutes="$2"
  local system_prompt="$3"
  local task_prompt="$4"
  local output_file="$5"
  local before=""
  local after=""
  local status=0

  before="$(working_tree_fingerprint)"
  run_agent "$phase" readonly "$timeout_minutes" "$system_prompt" "$task_prompt" "$output_file"
  status=$?
  after="$(working_tree_fingerprint)"

  if [[ "$before" != "$after" ]]; then
    touch "${ENGINE_ROOT}/readonly-phase-mutation-detected"
    echo "Read-only ${phase} agent modified the target working tree" >&2
    return 90
  fi
  return "$status"
}

write_runtime_result() {
  local status="$1"
  local summary="$2"
  local next_step="$3"

  jq -n \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg next_step "$next_step" \
    '{
      status: $status,
      summary: $summary,
      next_step: $next_step,
      tests: [],
      findings: [$summary]
    }' >"$RESULT_FILE"

  cat >"$HANDOFF_FILE" <<EOF
# Handoff

Status: ${status}

${summary}

Next step: ${next_step}
EOF
}

write_review_handoff() {
  {
    printf '# Handoff\n\n'
    printf 'Review status: **%s**\n\n' "$(jq -r '.status' "$REVIEW_FILE")"
    printf '## Summary\n\n%s\n\n' "$(jq -r '.summary' "$REVIEW_FILE")"
    printf '## Findings\n\n'
    jq -r 'if (.findings | length) == 0 then "- None reported" else .findings[] | "- " + . end' "$REVIEW_FILE"
    printf '\n## Next step\n\n%s\n' "$(jq -r '.next_step' "$REVIEW_FILE")"
  } >"$HANDOFF_FILE"
}

finish_round() {
  local leak_sentinel="${ENGINE_ROOT}/credential-leak-detected"

  if git grep --untracked --exclude-standard -I -F -q -- "$ANTHROPIC_AUTH_TOKEN"; then
    touch "$leak_sentinel"
    jq -n '{
      status: "blocked",
      summary: "A configured model credential appeared in the working tree, so no changes were published.",
      next_step: "Rotate the affected credential and inspect the failed run before retrying.",
      tests: [],
      findings: ["critical: configured model credential detected in the working tree"]
    }' >"$RESULT_FILE"
  fi
  unset ANTHROPIC_AUTH_TOKEN
  exit 0
}

for value in "$ANALYSIS_TIMEOUT_MINUTES" "$IMPLEMENTATION_TIMEOUT_MINUTES" \
  "$VERIFICATION_TIMEOUT_MINUTES" "$REVIEW_TIMEOUT_MINUTES"; do
  if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < 1 || value > 60)); then
    echo "Agent phase timeouts must be integers between 1 and 60 minutes" >&2
    exit 1
  fi
done

for command in git jq timeout claude tee; do
  require_command "$command"
done

for source in "$ISSUE_FILE" "$STATE_FILE" "$COMMON_SYSTEM" "$ANALYST_SYSTEM" \
  "$IMPLEMENTER_SYSTEM" "$VERIFIER_SYSTEM" "$REVIEWER_SYSTEM" \
  "$TASK_ANALYSIS_SKILL" "$DEBUGGING_SKILL" "$CYBER_DIVINATION_SKILL" \
  "$TEST_DRIVEN_SKILL" "$VERIFICATION_SKILL" "$REVIEW_SKILL"; do
  require_file "$source"
done

CLAUDE_HOME="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR" "$CLAUDE_HOME"' EXIT

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

mkdir -p "$STATE_DIR"
rm -f "$ANALYSIS_FILE" "$IMPLEMENTATION_FILE" "$VERIFICATION_FILE" \
  "$REVIEW_FILE" "$RESULT_FILE"

ANALYST_COMBINED_SYSTEM="${TEMP_DIR}/analyst-system.md"
IMPLEMENTER_COMBINED_SYSTEM="${TEMP_DIR}/implementer-system.md"
VERIFIER_COMBINED_SYSTEM="${TEMP_DIR}/verifier-system.md"
REVIEWER_COMBINED_SYSTEM="${TEMP_DIR}/reviewer-system.md"
build_system_prompt "$ANALYST_COMBINED_SYSTEM" \
  "$COMMON_SYSTEM" "$ANALYST_SYSTEM" "$TASK_ANALYSIS_SKILL" "$DEBUGGING_SKILL" \
  "$CYBER_DIVINATION_SKILL"
build_system_prompt "$IMPLEMENTER_COMBINED_SYSTEM" \
  "$COMMON_SYSTEM" "$IMPLEMENTER_SYSTEM" "$TEST_DRIVEN_SKILL"
build_system_prompt "$VERIFIER_COMBINED_SYSTEM" \
  "$COMMON_SYSTEM" "$VERIFIER_SYSTEM" "$VERIFICATION_SKILL"
build_system_prompt "$REVIEWER_COMBINED_SYSTEM" \
  "$COMMON_SYSTEM" "$REVIEWER_SYSTEM" "$REVIEW_SKILL"

ANALYST_TASK="${TEMP_DIR}/analyst-task.md"
cat >"$ANALYST_TASK" <<EOF
Perform the analyst phase for issue #${ISSUE_NUMBER}.

- Issue snapshot: ${ISSUE_FILE}
- Lifecycle state: ${STATE_FILE}
- Previous handoff: ${HANDOFF_FILE}

Inspect the target repository, follow the analyst system prompt, and return the
required JSON analysis as your final response. Do not modify repository files.
EOF

ANALYST_OUTPUT="${TEMP_DIR}/analysis.json"
set +e
run_readonly_agent analyst "$ANALYSIS_TIMEOUT_MINUTES" \
  "$ANALYST_COMBINED_SYSTEM" "$ANALYST_TASK" "$ANALYST_OUTPUT"
analyst_status=$?
set -e

if [[ "$analyst_status" -ne 0 || ! -s "$ANALYST_OUTPUT" ]]; then
  if [[ "$analyst_status" -eq 124 ]]; then
    write_runtime_result continue \
      "The analyst agent reached its timeout before producing an implementation brief." \
      "Resume analysis from the current issue and previous handoff."
  else
    write_runtime_result blocked \
      "The analyst agent failed before producing an implementation brief (exit ${analyst_status})." \
      "Inspect the workflow log and fix the analyst runtime or prompt contract."
  fi
  finish_round
fi

normalize_agent_json "$ANALYST_OUTPUT"
if ! jq -e '
  (.status == "ready" or .status == "satisfied" or .status == "blocked"
    or .status == "insufficient_evidence")
  and (.task_type == "bug" or .task_type == "feature" or .task_type == "refactor"
    or .task_type == "documentation" or .task_type == "build_ci" or .task_type == "mixed")
  and (.summary | type == "string" and length > 0)
  and (.evidence | type == "array")
  and all(.evidence[]; type == "string")
  and (.root_cause_or_rationale | type == "string" and length > 0)
  and (.implementation_plan | type == "array")
  and all(.implementation_plan[]; type == "string")
  and (.validation_plan | type == "array")
  and all(.validation_plan[]; type == "string")
  and (.risks | type == "array")
  and all(.risks[]; type == "string")
  and (.status != "ready" or (.implementation_plan | length) > 0)
  and (.status != "ready" or (.validation_plan | length) > 0)
  and (.status != "satisfied" or (.validation_plan | length) > 0)
  and (.status != "insufficient_evidence" or (.implementation_plan | length) == 0)
' "$ANALYST_OUTPUT" >/dev/null 2>&1; then
  write_runtime_result blocked \
    "The analyst did not produce a result matching the required JSON contract." \
    "Inspect the workflow log and correct the analyst prompt or runtime."
  finish_round
fi
cp "$ANALYST_OUTPUT" "$ANALYSIS_FILE"

if [[ "$(jq -r '.status' "$ANALYSIS_FILE")" == "blocked" ]]; then
  write_runtime_result blocked \
    "$(jq -r '.summary' "$ANALYSIS_FILE")" \
    "Resolve the analyst-reported risks or unavailable dependency before retrying."
  finish_round
fi

if [[ "$(jq -r '.status' "$ANALYSIS_FILE")" == "satisfied" ]]; then
  # The analyst evidenced that the requested outcome is already met, so there is
  # no increment to implement, verify, or review. Finalize the round directly,
  # recording the analyst's validation plan and evidence so the claim is auditable.
  jq '{
    status: "complete",
    summary: .summary,
    next_step: "No code change was required; the requested outcome was already satisfied.",
    tests: .validation_plan,
    findings: .evidence
  }' "$ANALYSIS_FILE" >"$RESULT_FILE"
  {
    printf '# Handoff\n\n'
    printf 'Status: complete\n\n'
    printf '%s\n\n' "$(jq -r '.summary' "$ANALYSIS_FILE")"
    printf 'Next step: No code change was required; the requested outcome was already satisfied.\n'
  } >"$HANDOFF_FILE"
  finish_round
fi

if [[ "$(jq -r '.status' "$ANALYSIS_FILE")" == "insufficient_evidence" ]]; then
  # The issue carries no actionable information, so the analyst replied through
  # the cyber-divination evidence gate instead of guessing a fix. Post that
  # hexagram reply to the issue and stop the round before the implementer; do
  # not create a branch or pull request for a fake or empty issue.
  jq '{
    status: "blocked",
    summary: .summary,
    next_step: "补充日志、截图/录屏、复现步骤、环境与版本后，重新添加 solve-it 触发分析。",
    tests: [],
    findings: .evidence,
    publish_changes: false
  }' "$ANALYSIS_FILE" >"$RESULT_FILE"
  {
    printf '# Handoff\n\n'
    printf 'Status: blocked (insufficient evidence)\n\n'
    jq -r '.summary' "$ANALYSIS_FILE"
    printf '\n'
  } >"$HANDOFF_FILE"
  finish_round
fi

IMPLEMENTER_TASK="${TEMP_DIR}/implementer-task.md"
cat >"$IMPLEMENTER_TASK" <<EOF
Perform the implementer phase for issue #${ISSUE_NUMBER}.

- Issue snapshot: ${ISSUE_FILE}
- Lifecycle state: ${STATE_FILE}
- Previous handoff: ${HANDOFF_FILE}
- Analyst artifact: ${ANALYSIS_FILE}

Read the analyst artifact before editing. Implement one coherent increment,
validate it, and return the required JSON implementation report as your final
response. The reviewer, not you, decides the final status.
EOF

IMPLEMENTER_OUTPUT="${TEMP_DIR}/implementation.json"
state_before_implementer="$(state_tree_fingerprint)"
set +e
run_agent implementer bypassPermissions "$IMPLEMENTATION_TIMEOUT_MINUTES" \
  "$IMPLEMENTER_COMBINED_SYSTEM" "$IMPLEMENTER_TASK" "$IMPLEMENTER_OUTPUT"
implementer_status=$?
set -e
state_after_implementer="$(state_tree_fingerprint)"

if [[ "$state_before_implementer" != "$state_after_implementer" ]]; then
  touch "${ENGINE_ROOT}/protected-state-mutation-detected"
  write_runtime_result blocked \
    "The implementer modified wrapper-owned .agent_state/issues content." \
    "Inspect the failed run and correct the implementer prompt or runtime."
  finish_round
fi

if [[ -s "$IMPLEMENTER_OUTPUT" ]]; then
  normalize_agent_json "$IMPLEMENTER_OUTPUT"
  if ! jq -e '
    (.status == "ready_for_verification" or .status == "blocked")
    and (.summary | type == "string" and length > 0)
    and (.changes | type == "array")
    and all(.changes[]; type == "string")
    and (.tests | type == "array")
    and all(.tests[]; type == "string")
    and (.deviations | type == "array")
    and all(.deviations[]; type == "string")
    and (.remaining_concerns | type == "array")
    and all(.remaining_concerns[]; type == "string")
    and (.status != "ready_for_verification" or (.changes | length) > 0)
  ' "$IMPLEMENTER_OUTPUT" >/dev/null 2>&1; then
    write_runtime_result blocked \
      "The implementer did not produce a result matching the required JSON contract." \
      "Inspect the workflow log and correct the implementer prompt or runtime."
    finish_round
  fi
  cp "$IMPLEMENTER_OUTPUT" "$IMPLEMENTATION_FILE"
else
  jq -n \
    --arg status "$implementer_status" \
    '{
      status: "blocked",
      summary: ("The implementer exited without a report (exit " + $status + ")."),
      changes: [],
      tests: [],
      deviations: [],
      remaining_concerns: ["Review the actual working tree for partial changes."]
    }' >"$IMPLEMENTATION_FILE"
fi

VERIFIER_TASK="${TEMP_DIR}/verifier-task.md"
cat >"$VERIFIER_TASK" <<EOF
Perform the independent verifier phase for issue #${ISSUE_NUMBER}.

- Issue snapshot: ${ISSUE_FILE}
- Lifecycle state: ${STATE_FILE}
- Previous handoff: ${HANDOFF_FILE}
- Analyst artifact: ${ANALYSIS_FILE}
- Implementation report: ${IMPLEMENTATION_FILE}
- Implementer exit status: ${implementer_status}

Inspect the actual working tree and git diff. Follow the verifier system prompt
and return only the required JSON object as your final response. Do not modify
repository files.
EOF

VERIFIER_OUTPUT="${TEMP_DIR}/verification.json"
set +e
run_readonly_agent verifier "$VERIFICATION_TIMEOUT_MINUTES" \
  "$VERIFIER_COMBINED_SYSTEM" "$VERIFIER_TASK" "$VERIFIER_OUTPUT"
verifier_status=$?
set -e

if [[ "$verifier_status" -ne 0 || ! -s "$VERIFIER_OUTPUT" ]]; then
  if [[ "$verifier_status" -eq 124 ]]; then
    write_runtime_result continue \
      "The verifier agent reached its timeout before producing independent evidence." \
      "Resume verification of the current implementation in the next round."
  else
    write_runtime_result blocked \
      "The verifier agent failed before producing independent evidence (exit ${verifier_status})." \
      "Inspect the workflow log and fix the verifier runtime or prompt contract."
  fi
  finish_round
fi

normalize_agent_json "$VERIFIER_OUTPUT"
if ! jq -e '
  (.status == "pass" or .status == "fail" or .status == "blocked")
  and (.summary | type == "string" and length > 0)
  and (.tests | type == "array")
  and all(.tests[]; type == "string")
  and (.acceptance_checks | type == "array")
  and all(.acceptance_checks[]; type == "string")
  and (.findings | type == "array")
  and all(.findings[]; type == "string")
  and (.status != "pass" or (.tests | length) > 0)
  and (.status != "pass" or (.acceptance_checks | length) > 0)
' "$VERIFIER_OUTPUT" >/dev/null 2>&1; then
  write_runtime_result blocked \
    "The verifier did not produce a result matching the required JSON contract." \
    "Inspect the workflow log and correct the verifier prompt or runtime."
  finish_round
fi
cp "$VERIFIER_OUTPUT" "$VERIFICATION_FILE"

REVIEWER_TASK="${TEMP_DIR}/reviewer-task.md"
cat >"$REVIEWER_TASK" <<EOF
Perform the independent reviewer phase for issue #${ISSUE_NUMBER}.

- Issue snapshot: ${ISSUE_FILE}
- Lifecycle state: ${STATE_FILE}
- Previous handoff: ${HANDOFF_FILE}
- Analyst artifact: ${ANALYSIS_FILE}
- Implementation report: ${IMPLEMENTATION_FILE}
- Verifier artifact: ${VERIFICATION_FILE}
- Implementer exit status: ${implementer_status}

Inspect the actual working tree and git diff. Follow the reviewer system prompt
and return only the required JSON object as your final response. Do not modify
repository files.
EOF

REVIEWER_OUTPUT="${TEMP_DIR}/review.json"
set +e
run_readonly_agent reviewer "$REVIEW_TIMEOUT_MINUTES" \
  "$REVIEWER_COMBINED_SYSTEM" "$REVIEWER_TASK" "$REVIEWER_OUTPUT"
reviewer_status=$?
set -e

if [[ "$reviewer_status" -ne 0 || ! -s "$REVIEWER_OUTPUT" ]]; then
  if [[ "$reviewer_status" -eq 124 ]]; then
    write_runtime_result continue \
      "The reviewer agent reached its timeout before deciding the round status." \
      "Review the current diff and implementation report in the next round."
  else
    write_runtime_result blocked \
      "The reviewer agent failed before deciding the round status (exit ${reviewer_status})." \
      "Inspect the workflow log and fix the reviewer runtime or prompt contract."
  fi
  finish_round
fi

normalize_agent_json "$REVIEWER_OUTPUT"
verification_status="$(jq -r '.status' "$VERIFICATION_FILE")"
if ! jq -e --arg verification_status "$verification_status" '
  (.status == "continue" or .status == "complete" or .status == "blocked")
  and (.summary | type == "string" and length > 0)
  and (.next_step | type == "string")
  and (.tests | type == "array")
  and all(.tests[]; type == "string")
  and (.findings | type == "array")
  and all(.findings[]; type == "string")
  and (.status != "complete" or (.tests | length) > 0)
  and (.status != "complete" or $verification_status == "pass")
  and ($verification_status != "blocked" or .status == "blocked")
' "$REVIEWER_OUTPUT" >/dev/null 2>&1; then
  write_runtime_result blocked \
    "The reviewer did not produce a result matching the required JSON contract." \
    "Inspect the workflow log and correct the reviewer prompt or runtime."
  finish_round
fi

cp "$REVIEWER_OUTPUT" "$REVIEW_FILE"
cp "$REVIEW_FILE" "$RESULT_FILE"
write_review_handoff
finish_round
