#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

cases_file="${test_root}/cases.yml"
providers_file="${test_root}/providers.yml"
rubric_file="${test_root}/rubric.yml"
results_file="${test_root}/results.jsonl"
report_file="${test_root}/report.md"

cat >"$cases_file" <<'EOF'
cases:
  - id: sample-docs
    title: Sample documentation task
    source_repository: owner/repo
    source_commit: 0123456789abcdef0123456789abcdef01234567
    target_repository: owner/target
    target_ref: benchmark/sample-docs
    task_type: documentation
    max_rounds: 2
    issue_body: |
      Update docs.
      Preserve this second line.
    validation_commands:
      - git diff --check
      - printf 'multi line command check\n'
EOF

cat >"$providers_file" <<'EOF'
providers:
  - id: vendor-a
    workflow_provider: deepseek
    model: model-a
    secret: VENDOR_A_KEY
  - id: vendor-b
    workflow_provider: mimo
    model: model-b
    secret: VENDOR_B_KEY
EOF

cat >"$rubric_file" <<'EOF'
weights:
  completion: 50
  rounds: 15
  change_quality: 15
  verification: 10
  stability: 10
round_penalty: 5
finding_penalties:
  critical: 15
  high: 10
  medium: 5
  low: 2
EOF

bash "${repo_root}/.agent/scripts/benchmark.sh" validate-config \
  --cases "$cases_file" \
  --providers "$providers_file" \
  --rubric "$rubric_file" >/dev/null

cat >"$results_file" <<'EOF'
{"case_id":"sample-docs","provider_id":"vendor-a","status":"complete","round":1,"max_rounds":2,"verification_status":"pass","findings":[],"pr_url":"https://example.test/pr/1"}
{"case_id":"sample-docs","provider_id":"vendor-b","status":"blocked","round":2,"max_rounds":2,"verification_status":"fail","findings":["high: missing acceptance coverage"],"pr_url":""}
EOF

bash "${repo_root}/.agent/scripts/benchmark.sh" report \
  --input "$results_file" \
  --rubric "$rubric_file" \
  --out "$report_file"

grep -q '# Agent Benchmark Report' "$report_file"
grep -q '| vendor-a | 1 | 100.0 | 1 | 1.0 | 0 |' "$report_file"
grep -q '| vendor-b | 1 | 15.0 | 0 | 2.0 | 0 |' "$report_file"

bash "$repo_root/agent-cycle" help | grep -q 'benchmark'

fake_bin="${test_root}/bin"
created_bodies="${test_root}/created-bodies"
mkdir -p "$fake_bin" "$created_bodies"
cat >"${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "label create")
    exit 0
    ;;
  "issue list")
    if [[ -n "${BENCHMARK_FAKE_ISSUE_NUMBER:-}" ]]; then
      printf '%s\n' "$BENCHMARK_FAKE_ISSUE_NUMBER"
    fi
    exit 0
    ;;
  "issue create")
    body_file=""
    while (($#)); do
      case "$1" in
        --body-file)
          body_file="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ -n "$body_file" ]] || exit 2
    cp "$body_file" "${BENCHMARK_CREATED_BODIES}/body-${RANDOM}.md"
    printf 'https://example.test/issues/new\n'
    ;;
  "workflow run")
    printf '%s\n' "$*" >>"${BENCHMARK_WORKFLOW_CALLS}"
    ;;
  "pr list")
    printf '{}\n'
    ;;
  *)
    if [[ "${1:-}" == "api" ]]; then
      case "$*" in
        *"git/ref/heads/benchmark/sample-docs"*)
          if [[ "${BENCHMARK_TARGET_REF_MISSING:-}" == true ]]; then
            exit 1
          fi
          printf '%s\n' 'fedcba9876543210fedcba9876543210fedcba98'
          ;;
        *"compare/0123456789abcdef0123456789abcdef01234567...fedcba9876543210fedcba9876543210fedcba98"*)
          printf '%s\n' 'ahead'
          ;;
        *"contents/.agent_state/issues/42/state.json?ref=agent/issue-42"*)
          ruby -rbase64 -e 'print Base64.strict_encode64(ARGV.fetch(0))' \
            '{"issue":42,"round":2,"max_rounds":2,"base_ref":"benchmark/sample-docs","base_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider":"deepseek","status":"complete","last_summary":"done"}'
          ;;
        *"contents/.agent_state/issues/42/result.json?ref=agent/issue-42"*)
          ruby -rbase64 -e 'print Base64.strict_encode64(ARGV.fetch(0))' \
            '{"status":"complete","summary":"done","findings":[],"tests":[]}'
          ;;
        *"contents/.agent_state/issues/42/verification.json?ref=agent/issue-42"*)
          ruby -rbase64 -e 'print Base64.strict_encode64(ARGV.fetch(0))' \
            '{"status":"pass"}'
          ;;
        *".agent/scripts/benchmark.sh"*)
          cat "${BENCHMARK_REPO_ROOT}/.agent/scripts/benchmark.sh"
          ;;
        *"benchmarks/cases.yml"*)
          cat "${BENCHMARK_REPO_ROOT}/benchmarks/cases.yml"
          ;;
        *"benchmarks/providers.yml"*)
          cat "${BENCHMARK_REPO_ROOT}/benchmarks/providers.yml"
          ;;
        *"benchmarks/rubric.yml"*)
          cat "${BENCHMARK_REPO_ROOT}/benchmarks/rubric.yml"
          ;;
        *)
          printf 'unexpected gh api call: %s\n' "$*" >&2
          exit 2
          ;;
      esac
    else
      printf 'unexpected gh call: %s\n' "$*" >&2
      exit 2
    fi
    ;;
esac
EOF
chmod +x "${fake_bin}/gh"

GH_BIN="${fake_bin}/gh" \
  BENCHMARK_CREATED_BODIES="$created_bodies" \
  bash "${repo_root}/.agent/scripts/benchmark.sh" create-issues \
    --target-repo owner/target \
    --cases "$cases_file" \
    --providers "$providers_file" >/dev/null

test "$(find "$created_bodies" -type f | wc -l | tr -d ' ')" = 2
grep -R "Preserve this second line." "$created_bodies" >/dev/null
grep -R "printf 'multi line command check" "$created_bodies" >/dev/null

no_target_cases="${test_root}/no-target-cases.yml"
cat >"$no_target_cases" <<'EOF'
cases:
  - id: no-target
    title: No target repository task
    source_repository: owner/source
    source_commit: 0123456789abcdef0123456789abcdef01234567
    target_ref: benchmark/no-target
    task_type: documentation
    max_rounds: 1
    issue_body: |
      Update docs.
    validation_commands:
      - git diff --check
EOF
set +e
GH_BIN="${fake_bin}/gh" \
  bash "${repo_root}/.agent/scripts/benchmark.sh" create-issues \
    --target-repo wrong/default \
    --cases "$no_target_cases" \
    --providers "$providers_file" >"${test_root}/mismatch.out" 2>"${test_root}/mismatch.err"
mismatch_status=$?
set -e
test "$mismatch_status" -ne 0
grep -q "use target_repository" "${test_root}/mismatch.err"

missing_ref_cases="${test_root}/missing-ref-cases.yml"
cat >"$missing_ref_cases" <<'EOF'
cases:
  - id: missing-ref
    title: Missing target ref task
    source_repository: owner/source
    source_commit: 0123456789abcdef0123456789abcdef01234567
    task_type: documentation
    max_rounds: 1
    issue_body: |
      Update docs.
    validation_commands:
      - git diff --check
EOF
set +e
bash "${repo_root}/.agent/scripts/benchmark.sh" validate-config \
  --cases "$missing_ref_cases" \
  --providers "$providers_file" \
  --rubric "$rubric_file" >"${test_root}/missing-ref.out" 2>"${test_root}/missing-ref.err"
missing_ref_status=$?
set -e
test "$missing_ref_status" -ne 0
grep -q "missing target_ref" "${test_root}/missing-ref.err"

sha_ref_cases="${test_root}/sha-ref-cases.yml"
cat >"$sha_ref_cases" <<'EOF'
cases:
  - id: sha-ref
    title: SHA target ref task
    source_repository: owner/source
    source_commit: 0123456789abcdef0123456789abcdef01234567
    target_ref: 0123456789abcdef0123456789abcdef01234567
    task_type: documentation
    max_rounds: 1
    issue_body: |
      Update docs.
    validation_commands:
      - git diff --check
EOF
set +e
bash "${repo_root}/.agent/scripts/benchmark.sh" validate-config \
  --cases "$sha_ref_cases" \
  --providers "$providers_file" \
  --rubric "$rubric_file" >"${test_root}/sha-ref.out" 2>"${test_root}/sha-ref.err"
sha_ref_status=$?
set -e
test "$sha_ref_status" -ne 0
grep -q "target_ref must not be a raw commit SHA" "${test_root}/sha-ref.err"

for invalid_rounds in "3.5" "3abc" "21"; do
  invalid_rounds_cases="${test_root}/invalid-rounds-${invalid_rounds}.yml"
  cat >"$invalid_rounds_cases" <<EOF
cases:
  - id: invalid-rounds
    title: Invalid max rounds task
    source_repository: owner/source
    source_commit: 0123456789abcdef0123456789abcdef01234567
    target_ref: benchmark/invalid-rounds
    task_type: documentation
    max_rounds: ${invalid_rounds}
    issue_body: |
      Update docs.
    validation_commands:
      - git diff --check
EOF
  set +e
  bash "${repo_root}/.agent/scripts/benchmark.sh" validate-config \
    --cases "$invalid_rounds_cases" \
    --providers "$providers_file" \
    --rubric "$rubric_file" >"${test_root}/invalid-rounds-${invalid_rounds}.out" 2>"${test_root}/invalid-rounds-${invalid_rounds}.err"
  invalid_rounds_status=$?
  set -e
  test "$invalid_rounds_status" -ne 0
  grep -q "max_rounds must be an integer between 1 and 20" "${test_root}/invalid-rounds-${invalid_rounds}.err"
done

for invalid_override in "3.5" "3abc" "21"; do
  set +e
  GH_BIN="${fake_bin}/gh" \
    BENCHMARK_FAKE_ISSUE_NUMBER=42 \
    BENCHMARK_WORKFLOW_CALLS="${test_root}/invalid-override-${invalid_override}.log" \
    bash "${repo_root}/.agent/scripts/benchmark.sh" run \
      --target-repo owner/target \
      --cases "$cases_file" \
      --providers "$providers_file" \
      --max-rounds "$invalid_override" >"${test_root}/invalid-override-${invalid_override}.out" 2>"${test_root}/invalid-override-${invalid_override}.err"
  invalid_override_status=$?
  set -e
  test "$invalid_override_status" -ne 0
  grep -q "max_rounds must be an integer between 1 and 20" "${test_root}/invalid-override-${invalid_override}.err"
done

workflow_calls="${test_root}/workflow-calls.log"
GH_BIN="${fake_bin}/gh" \
  BENCHMARK_FAKE_ISSUE_NUMBER=42 \
  BENCHMARK_WORKFLOW_CALLS="$workflow_calls" \
  bash "${repo_root}/.agent/scripts/benchmark.sh" run \
    --target-repo wrong/default \
    --cases "$cases_file" \
    --providers "$providers_file" >/dev/null

grep -q -- '--repo owner/target' "$workflow_calls"
grep -q -- '--ref benchmark/sample-docs' "$workflow_calls"
grep -q -- '-f provider=deepseek' "$workflow_calls"
grep -q -- '-f provider=mimo' "$workflow_calls"
grep -q -- '-f base_ref=benchmark/sample-docs' "$workflow_calls"
grep -q -- '-f base_sha=fedcba9876543210fedcba9876543210fedcba98' "$workflow_calls"

collect_file="${test_root}/collect.jsonl"
GH_BIN="${fake_bin}/gh" \
  BENCHMARK_FAKE_ISSUE_NUMBER=42 \
  BENCHMARK_TARGET_REF_MISSING=true \
  bash "${repo_root}/.agent/scripts/benchmark.sh" collect \
    --target-repo owner/target \
    --cases "$cases_file" \
    --providers "$providers_file" \
    --out "$collect_file"

test "$(wc -l <"$collect_file" | tr -d ' ')" = 2
grep -q '"base_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$collect_file"
grep -q '"target_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$collect_file"
grep -q '"current_target_sha":""' "$collect_file"

installed_bin="${test_root}/installed-bin"
empty_target="${test_root}/empty-target"
mkdir -p "$installed_bin" "$empty_target"
install -m 0755 "${repo_root}/agent-cycle" "${installed_bin}/agent-cycle"
(
  cd "$empty_target"
  AGENT_CYCLE_GH_BIN="${fake_bin}/gh" \
    BENCHMARK_REPO_ROOT="$repo_root" \
    AGENT_ENGINE_REPOSITORY="owner/engine" \
    AGENT_ENGINE_REF="test-ref" \
    "${installed_bin}/agent-cycle" benchmark validate-config >/dev/null
)

installed_bodies="${test_root}/installed-bodies"
mkdir -p "$installed_bodies"
(
  cd "$empty_target"
  AGENT_CYCLE_GH_BIN="${fake_bin}/gh" \
    BENCHMARK_REPO_ROOT="$repo_root" \
    BENCHMARK_CREATED_BODIES="$installed_bodies" \
    AGENT_ENGINE_REPOSITORY="owner/engine" \
    AGENT_ENGINE_REF="test-ref" \
    "${installed_bin}/agent-cycle" benchmark create-issues \
      --cases "$cases_file" \
      --providers "$providers_file" >/dev/null
)
test "$(find "$installed_bodies" -type f | wc -l | tr -d ' ')" = 2

echo "Benchmark tests passed"
