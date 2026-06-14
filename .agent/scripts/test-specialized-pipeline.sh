#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

make_target() {
  local target="$1"

  mkdir -p "${target}/.agent_state/issues/1"
  git init -q "$target"
  printf 'original\n' >"${target}/app.txt"
  printf '# Issue #1\n\nChange app behavior.\n' >"${target}/.agent_state/issues/1/issue.md"
  printf '{"issue":1,"round":1,"max_rounds":5,"provider":"deepseek","status":"running"}\n' \
    >"${target}/.agent_state/issues/1/state.json"
  git -C "$target" add .
  git -C "$target" -c user.name=test -c user.email=test@example.com commit -qm init
}

make_fake_timeout() {
  local bin_dir="$1"

  cat >"${bin_dir}/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  chmod +x "${bin_dir}/timeout"
}

run_fake_round() {
  local root="$1"
  local target="${root}/target"
  local engine="${root}/engine"
  local bin_dir="${root}/bin"

  PATH="${bin_dir}:$PATH" \
    ISSUE_NUMBER=1 \
    ENGINE_ROOT="$engine" \
    TARGET_ROOT="$target" \
    DEEPSEEK_API_KEY="pipeline-test-provider-key" \
    AGENT_ANALYSIS_TIMEOUT_MINUTES=1 \
    AGENT_IMPLEMENTATION_TIMEOUT_MINUTES=1 \
    AGENT_VERIFICATION_TIMEOUT_MINUTES=1 \
    AGENT_REVIEW_TIMEOUT_MINUTES=1 \
    bash "${engine}/scripts/run-round.sh" >/dev/null
}

setup_scenario() {
  local name="$1"
  local root="${test_root}/${name}"

  mkdir -p "${root}/bin"
  cp -R "${repo_root}/.agent" "${root}/engine"
  make_target "${root}/target"
  make_fake_timeout "${root}/bin"
  printf '%s\n' "$root"
}

success_root="$(setup_scenario success)"
cat >"${success_root}/bin/claude" <<'EOF'
#!/usr/bin/env bash
task="$(cat)"
case "$task" in
  *"analyst phase"*)
    printf '%s\n' '{"status":"ready","task_type":"feature","summary":"Change app content.","evidence":["app.txt contains original"],"root_cause_or_rationale":"The requested content is absent.","implementation_plan":["Update app.txt"],"validation_plan":["grep changed app.txt"],"risks":[]}'
    ;;
  *"implementer phase"*)
    test -s .agent_state/issues/1/analysis.json
    printf 'changed\n' >app.txt
    printf '%s\n' '{"status":"ready_for_verification","summary":"Updated app content.","changes":["app.txt: changed content"],"tests":["grep changed app.txt: passed"],"deviations":[],"remaining_concerns":[]}'
    ;;
  *"verifier phase"*)
    test -s .agent_state/issues/1/implementation.json
    grep -q changed app.txt
    printf '%s\n' '{"status":"pass","summary":"Verified changed content.","tests":["grep changed app.txt: passed"],"acceptance_checks":["app changed: pass - observed changed"],"findings":[]}'
    ;;
  *"reviewer phase"*)
    test -s .agent_state/issues/1/verification.json
    printf '%s\n' '{"status":"complete","summary":"Implementation satisfies the issue.","next_step":"Review and merge.","tests":["grep changed app.txt: passed"],"findings":[]}'
    ;;
  *) exit 7 ;;
esac
EOF
chmod +x "${success_root}/bin/claude"
run_fake_round "$success_root"
test "$(jq -r '.status' "${success_root}/target/.agent_state/issues/1/result.json")" = complete
test -s "${success_root}/target/.agent_state/issues/1/analysis.json"
test -s "${success_root}/target/.agent_state/issues/1/implementation.json"
test -s "${success_root}/target/.agent_state/issues/1/verification.json"
test -s "${success_root}/target/.agent_state/issues/1/review.json"
grep -q changed "${success_root}/target/app.txt"

gate_root="$(setup_scenario verifier-gate)"
cat >"${gate_root}/bin/claude" <<'EOF'
#!/usr/bin/env bash
task="$(cat)"
case "$task" in
  *"analyst phase"*)
    printf '%s\n' '{"status":"ready","task_type":"bug","summary":"Investigate app.","evidence":["app.txt exists"],"root_cause_or_rationale":"Content is incorrect.","implementation_plan":["Update app.txt"],"validation_plan":["check app"],"risks":[]}'
    ;;
  *"implementer phase"*)
    printf 'changed\n' >app.txt
    printf '%s\n' '{"status":"ready_for_verification","summary":"Updated app.","changes":["app.txt: changed"],"tests":[],"deviations":[],"remaining_concerns":[]}'
    ;;
  *"verifier phase"*)
    printf '%s\n' '{"status":"fail","summary":"Acceptance check failed.","tests":["check app: failed"],"acceptance_checks":["behavior: fail - still wrong"],"findings":["high: behavior remains wrong"]}'
    ;;
  *"reviewer phase"*)
    printf '%s\n' '{"status":"complete","summary":"Incorrect approval.","next_step":"Merge.","tests":["check app: failed"],"findings":[]}'
    ;;
  *) exit 7 ;;
esac
EOF
chmod +x "${gate_root}/bin/claude"
run_fake_round "$gate_root"
test "$(jq -r '.status' "${gate_root}/target/.agent_state/issues/1/result.json")" = blocked

mutation_root="$(setup_scenario readonly-mutation)"
cat >"${mutation_root}/bin/claude" <<'EOF'
#!/usr/bin/env bash
task="$(cat)"
if [[ "$task" == *"analyst phase"* ]]; then
  printf 'unauthorized\n' >app.txt
  printf '%s\n' '{"status":"ready","task_type":"feature","summary":"Changed without authority.","evidence":[],"root_cause_or_rationale":"None.","implementation_plan":[],"validation_plan":[],"risks":[]}'
else
  exit 7
fi
EOF
chmod +x "${mutation_root}/bin/claude"
run_fake_round "$mutation_root" 2>/dev/null
test -f "${mutation_root}/engine/readonly-phase-mutation-detected"
test "$(jq -r '.status' "${mutation_root}/target/.agent_state/issues/1/result.json")" = blocked

state_mutation_root="$(setup_scenario protected-state-mutation)"
cat >"${state_mutation_root}/bin/claude" <<'EOF'
#!/usr/bin/env bash
task="$(cat)"
case "$task" in
  *"analyst phase"*)
    printf '%s\n' '{"status":"ready","task_type":"feature","summary":"Change app.","evidence":["app.txt exists"],"root_cause_or_rationale":"A change is requested.","implementation_plan":["Update app.txt"],"validation_plan":["check app"],"risks":[]}'
    ;;
  *"implementer phase"*)
    printf '{"status":"forged"}\n' >.agent_state/issues/1/state.json
    printf '%s\n' '{"status":"ready_for_verification","summary":"Updated state.","changes":["state.json: forged"],"tests":[],"deviations":[],"remaining_concerns":[]}'
    ;;
  *) exit 7 ;;
esac
EOF
chmod +x "${state_mutation_root}/bin/claude"
run_fake_round "$state_mutation_root"
test -f "${state_mutation_root}/engine/protected-state-mutation-detected"
test "$(jq -r '.status' "${state_mutation_root}/target/.agent_state/issues/1/result.json")" = blocked

credential_root="$(setup_scenario credential-leak)"
cat >"${credential_root}/bin/claude" <<'EOF'
#!/usr/bin/env bash
task="$(cat)"
case "$task" in
  *"analyst phase"*)
    printf '%s\n' '{"status":"ready","task_type":"feature","summary":"Change app.","evidence":["app.txt exists"],"root_cause_or_rationale":"A change is requested.","implementation_plan":["Update app.txt"],"validation_plan":["check app"],"risks":[]}'
    ;;
  *"implementer phase"*)
    printf 'pipeline-test-provider-key\n' >leak.txt
    printf '%s\n' '{"status":"ready_for_verification","summary":"Updated app.","changes":["leak.txt: added"],"tests":[],"deviations":[],"remaining_concerns":[]}'
    ;;
  *"verifier phase"*)
    printf '%s\n' '{"status":"pass","summary":"Verified output.","tests":["check app: passed"],"acceptance_checks":["output: pass - observed"],"findings":[]}'
    ;;
  *"reviewer phase"*)
    printf '%s\n' '{"status":"complete","summary":"Implementation satisfies the issue.","next_step":"Review and merge.","tests":["check app: passed"],"findings":[]}'
    ;;
  *) exit 7 ;;
esac
EOF
chmod +x "${credential_root}/bin/claude"
run_fake_round "$credential_root"
test -f "${credential_root}/engine/credential-leak-detected"
test "$(jq -r '.status' "${credential_root}/target/.agent_state/issues/1/result.json")" = blocked

fenced_root="$(setup_scenario fenced-output)"
cat >"${fenced_root}/bin/claude" <<'EOF'
#!/usr/bin/env bash
task="$(cat)"
case "$task" in
  *"analyst phase"*)
    printf '%s\n' 'The requested change is not yet present.'
    printf '%s\n' '```json'
    printf '%s\n' '{"status":"ready","task_type":"feature","summary":"Change app content.","evidence":["app.txt contains original"],"root_cause_or_rationale":"The requested content is absent.","implementation_plan":["Update app.txt"],"validation_plan":["grep -E '\''changed\|original'\'' app.txt"],"risks":[]}'
    printf '%s\n' '```'
    ;;
  *"implementer phase"*)
    test -s .agent_state/issues/1/analysis.json
    printf 'changed\n' >app.txt
    printf '%s\n' 'Here is the implementation report:'
    printf '%s\n' '```json'
    printf '%s\n' '{"status":"ready_for_verification","summary":"Updated app content.","changes":["app.txt: changed content"],"tests":["grep changed app.txt: passed"],"deviations":[],"remaining_concerns":[]}'
    printf '%s\n' '```'
    ;;
  *"verifier phase"*)
    test -s .agent_state/issues/1/implementation.json
    grep -q changed app.txt
    printf '%s\n' '```json'
    printf '%s\n' '{"status":"pass","summary":"Verified changed content.","tests":["grep changed app.txt: passed"],"acceptance_checks":["app changed: pass - observed changed"],"findings":[]}'
    printf '%s\n' '```'
    ;;
  *"reviewer phase"*)
    test -s .agent_state/issues/1/verification.json
    printf '%s\n' 'Final decision below.'
    printf '%s\n' '```json'
    printf '%s\n' '{"status":"complete","summary":"Implementation satisfies the issue.","next_step":"Review and merge.","tests":["grep changed app.txt: passed"],"findings":[]}'
    printf '%s\n' '```'
    ;;
  *) exit 7 ;;
esac
EOF
chmod +x "${fenced_root}/bin/claude"
run_fake_round "$fenced_root"
test "$(jq -r '.status' "${fenced_root}/target/.agent_state/issues/1/result.json")" = complete
test "$(jq -r '.validation_plan[0]' "${fenced_root}/target/.agent_state/issues/1/analysis.json")" = "grep -E 'changed\\|original' app.txt"
grep -q changed "${fenced_root}/target/app.txt"

satisfied_root="$(setup_scenario already-satisfied)"
cat >"${satisfied_root}/bin/claude" <<'EOF'
#!/usr/bin/env bash
task="$(cat)"
case "$task" in
  *"analyst phase"*)
    printf '%s\n' '{"status":"satisfied","task_type":"feature","summary":"The requested behavior already exists in app.txt.","evidence":["app.txt already contains the required content"],"root_cause_or_rationale":"A prior change already implemented the requested outcome.","implementation_plan":[],"validation_plan":["grep original app.txt"],"risks":[]}'
    ;;
  *) exit 7 ;;
esac
EOF
chmod +x "${satisfied_root}/bin/claude"
run_fake_round "$satisfied_root"
test "$(jq -r '.status' "${satisfied_root}/target/.agent_state/issues/1/result.json")" = complete
test -s "${satisfied_root}/target/.agent_state/issues/1/analysis.json"
test ! -e "${satisfied_root}/target/.agent_state/issues/1/implementation.json"
test ! -e "${satisfied_root}/target/.agent_state/issues/1/verification.json"
test ! -e "${satisfied_root}/target/.agent_state/issues/1/review.json"
test "$(git -C "${satisfied_root}/target" status --porcelain app.txt)" = ""

echo "Specialized pipeline tests passed"
