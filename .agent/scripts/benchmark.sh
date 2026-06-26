#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
default_cases="${AGENT_BENCHMARK_CASES_FILE:-${repo_root}/benchmarks/cases.yml}"
default_providers="${AGENT_BENCHMARK_PROVIDERS_FILE:-${repo_root}/benchmarks/providers.yml}"
default_rubric="${AGENT_BENCHMARK_RUBRIC_FILE:-${repo_root}/benchmarks/rubric.yml}"
gh_bin="${GH_BIN:-gh}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Run open-source project benchmarks for Agent Cycle providers.

Usage:
  agent-cycle benchmark validate-config [--cases FILE] [--providers FILE] [--rubric FILE]
  agent-cycle benchmark create-issues [--target-repo OWNER/REPO] [--cases FILE] [--providers FILE] [--dry-run]
  agent-cycle benchmark run [--target-repo OWNER/REPO] [--cases FILE] [--providers FILE] [--max-rounds N] [--dry-run]
  agent-cycle benchmark collect [--target-repo OWNER/REPO] [--cases FILE] [--providers FILE] [--out FILE]
  agent-cycle benchmark report --input FILE [--rubric FILE] [--out FILE]

The benchmark creates one issue per case/provider pair so provider runs do not
share .agent_state or task branches. Cases may set target_repository and
target_ref; --target-repo is only the fallback for cases that omit a target.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

validate_max_rounds() {
  local value="$1"

  if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < 1 || value > 20)); then
    fail "max_rounds must be an integer between 1 and 20"
  fi
}

parse_config_args() {
  cases_file="$default_cases"
  providers_file="$default_providers"
  rubric_file="$default_rubric"
  while (($#)); do
    case "$1" in
      --cases)
        (($# >= 2)) || fail "--cases requires a value"
        cases_file="$2"
        shift 2
        ;;
      --providers)
        (($# >= 2)) || fail "--providers requires a value"
        providers_file="$2"
        shift 2
        ;;
      --rubric)
        (($# >= 2)) || fail "--rubric requires a value"
        rubric_file="$2"
        shift 2
        ;;
      *)
        return 0
        ;;
    esac
  done
  return 0
}

validate_config() {
  parse_config_args "$@"
  require_command ruby
  ruby - "$cases_file" "$providers_file" "$rubric_file" <<'RUBY'
require "yaml"

cases_path, providers_path, rubric_path = ARGV
cases = YAML.load_file(cases_path).fetch("cases")
providers = YAML.load_file(providers_path).fetch("providers")
rubric = YAML.load_file(rubric_path).fetch("weights")

def require_keys!(record, keys, label)
  keys.each do |key|
    value = record[key]
    abort "#{label} is missing #{key}" if value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end
end

case_ids = {}
cases.each_with_index do |record, index|
  label = "case #{index + 1}"
  require_keys!(record, %w[id title source_repository source_commit target_ref task_type max_rounds issue_body validation_commands], label)
  abort "#{label} source_repository must be OWNER/REPO" unless record["source_repository"].match?(%r{\A[\w.-]+/[\w.-]+\z})
  abort "#{label} source_commit must be a full commit SHA" unless record["source_commit"].match?(/\A[0-9a-f]{40}\z/i)
  if record["target_repository"]
    abort "#{label} target_repository must be OWNER/REPO" unless record["target_repository"].match?(%r{\A[\w.-]+/[\w.-]+\z})
  end
  abort "#{label} target_ref must not be a raw commit SHA; use a branch that exists in the target repository" if record["target_ref"].to_s.match?(/\A[0-9a-f]{40}\z/i)
  max_rounds = record["max_rounds"].to_s
  abort "#{label} max_rounds must be an integer between 1 and 20" unless max_rounds.match?(/\A[0-9]+\z/) && (1..20).cover?(max_rounds.to_i)
  abort "#{label} validation_commands must be an array" unless record["validation_commands"].is_a?(Array)
  abort "duplicate case id #{record["id"]}" if case_ids[record["id"]]
  case_ids[record["id"]] = true
end

provider_ids = {}
providers.each_with_index do |record, index|
  label = "provider #{index + 1}"
  require_keys!(record, %w[id workflow_provider model secret], label)
  abort "duplicate provider id #{record["id"]}" if provider_ids[record["id"]]
  provider_ids[record["id"]] = true
end

%w[completion rounds change_quality verification stability].each do |key|
  abort "rubric weight #{key} is missing" unless rubric[key].to_i.positive?
end

puts "Benchmark configuration is valid: #{cases.length} cases, #{providers.length} providers"
RUBY
}

emit_case_provider_rows() {
  local cases_path="$1"
  local providers_path="$2"
  ruby - "$cases_path" "$providers_path" <<'RUBY'
require "json"
require "yaml"
cases = YAML.load_file(ARGV[0]).fetch("cases")
providers = YAML.load_file(ARGV[1]).fetch("providers")
cases.each do |c|
  providers.each do |p|
    puts JSON.generate(
      "case_id" => c.fetch("id"),
      "provider_id" => p.fetch("id"),
      "workflow_provider" => p.fetch("workflow_provider"),
      "title" => c.fetch("title"),
      "source_repository" => c.fetch("source_repository"),
      "source_commit" => c.fetch("source_commit"),
      "target_repository" => c["target_repository"].to_s,
      "target_ref" => c.fetch("target_ref"),
      "max_rounds" => c.fetch("max_rounds"),
      "issue_body" => c.fetch("issue_body").to_s,
      "validation_commands" => Array(c.fetch("validation_commands"))
    )
  end
end
RUBY
}

record_field() {
  local record="$1"
  local expression="$2"

  jq -r "$expression" <<<"$record"
}

target_branch_sha() {
  local target_repo="$1"
  local target_ref="$2"

  "$gh_bin" api "repos/${target_repo}/git/ref/heads/${target_ref}" --jq '.object.sha'
}

ensure_target_branch_contains_source() {
  local target_repo="$1"
  local target_ref="$2"
  local source_commit="$3"
  local case_id="$4"
  local target_sha=""
  local compare_status=""

  target_sha="$(target_branch_sha "$target_repo" "$target_ref")" ||
    fail "case ${case_id} target_ref ${target_ref} must be an existing branch in ${target_repo}"
  compare_status="$("$gh_bin" api "repos/${target_repo}/compare/${source_commit}...${target_sha}" --jq '.status')" ||
    fail "case ${case_id} source_commit ${source_commit} is not comparable in ${target_repo}"
  case "$compare_status" in
    identical | ahead)
      printf '%s\n' "$target_sha"
      ;;
    *)
      fail "case ${case_id} target_ref ${target_ref} (${target_sha}) must contain source_commit ${source_commit}; compare status was ${compare_status}"
      ;;
  esac
}

resolve_target_repo() {
  local record="$1"
  local fallback_repo="$2"
  local case_id=""
  local source_repo=""
  local target_repo=""

  case_id="$(record_field "$record" '.case_id')"
  source_repo="$(record_field "$record" '.source_repository')"
  target_repo="$(record_field "$record" '.target_repository')"
  if [[ -n "$target_repo" ]]; then
    printf '%s\n' "$target_repo"
    return 0
  fi
  [[ -n "$fallback_repo" ]] ||
    fail "case ${case_id} needs target_repository or --target-repo"
  [[ "$fallback_repo" == "$source_repo" ]] ||
    fail "case ${case_id} source_repository is ${source_repo}; use target_repository for controlled forks instead of running it on ${fallback_repo}"
  printf '%s\n' "$fallback_repo"
}

find_issue_number() {
  local target_repo="$1"
  local case_id="$2"
  local provider_id="$3"
  local title_prefix="[benchmark:${case_id}:${provider_id}]"

  "$gh_bin" issue list \
    --repo "$target_repo" \
    --state all \
    --search "\"${title_prefix}\" in:title" \
    --json number,title \
    --jq ".[] | select(.title | startswith(\"${title_prefix}\")) | .number" |
    sed -n '1p'
}

create_issues() {
  local target_repo=""
  local dry_run=false
  local tmp_body=""

  cases_file="$default_cases"
  providers_file="$default_providers"
  while (($#)); do
    case "$1" in
      --target-repo)
        (($# >= 2)) || fail "--target-repo requires a value"
        target_repo="$2"
        shift 2
        ;;
      --cases)
        (($# >= 2)) || fail "--cases requires a value"
        cases_file="$2"
        shift 2
        ;;
      --providers)
        (($# >= 2)) || fail "--providers requires a value"
        providers_file="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        fail "unknown create-issues option: $1"
        ;;
    esac
  done

  validate_config --cases "$cases_file" --providers "$providers_file" --rubric "$default_rubric" >/dev/null
  require_command "$gh_bin"
  require_command jq
  tmp_body="$(mktemp)"
  trap 'rm -f "$tmp_body"' RETURN

  emit_case_provider_rows "$cases_file" "$providers_file" |
    while IFS= read -r record_json; do
      case_id="$(record_field "$record_json" '.case_id')"
      provider_id="$(record_field "$record_json" '.provider_id')"
      workflow_provider="$(record_field "$record_json" '.workflow_provider')"
      title="$(record_field "$record_json" '.title')"
      source_repo="$(record_field "$record_json" '.source_repository')"
      source_commit="$(record_field "$record_json" '.source_commit')"
      case_target_repo="$(resolve_target_repo "$record_json" "$target_repo")"
      case_target_ref="$(record_field "$record_json" '.target_ref')"
      ensure_target_branch_contains_source "$case_target_repo" "$case_target_ref" "$source_commit" "$case_id" >/dev/null
      max_rounds="$(record_field "$record_json" '.max_rounds')"
      issue_body="$(record_field "$record_json" '.issue_body')"
      validation_commands="$(record_field "$record_json" '.validation_commands | join("\n")')"
      if [[ "$dry_run" != true ]]; then
        "$gh_bin" label create agent-benchmark --repo "$case_target_repo" --color 5319e7 \
          --description "Agent benchmark task" --force >/dev/null
      fi
      issue_number="$(find_issue_number "$case_target_repo" "$case_id" "$provider_id")"
      if [[ -n "$issue_number" ]]; then
        printf 'exists issue #%s for %s/%s\n' "$issue_number" "$case_id" "$provider_id"
        continue
      fi

      cat >"$tmp_body" <<EOF
<!-- agent-benchmark
case_id: ${case_id}
provider_id: ${provider_id}
workflow_provider: ${workflow_provider}
source_repository: ${source_repo}
source_commit: ${source_commit}
target_repository: ${case_target_repo}
target_ref: ${case_target_ref}
-->

## Benchmark Task

${issue_body}

## Source

- Repository: ${source_repo}
- Commit: ${source_commit}
- Target repository: ${case_target_repo}
- Target ref: ${case_target_ref}
- Provider: ${provider_id}
- Max rounds: ${max_rounds}

## Acceptance Commands

\`\`\`bash
${validation_commands}
\`\`\`
EOF

      issue_title="[benchmark:${case_id}:${provider_id}] ${title}"
      if [[ "$dry_run" == true ]]; then
        printf 'would create issue: %s\n' "$issue_title"
      else
        "$gh_bin" issue create \
          --repo "$case_target_repo" \
          --title "$issue_title" \
          --body-file "$tmp_body" \
          --label agent-benchmark >/dev/null
        printf 'created issue for %s/%s\n' "$case_id" "$provider_id"
      fi
    done
}

run_matrix() {
  local target_repo=""
  local max_rounds_override=""
  local dry_run=false

  cases_file="$default_cases"
  providers_file="$default_providers"
  while (($#)); do
    case "$1" in
      --target-repo)
        (($# >= 2)) || fail "--target-repo requires a value"
        target_repo="$2"
        shift 2
        ;;
      --cases)
        (($# >= 2)) || fail "--cases requires a value"
        cases_file="$2"
        shift 2
        ;;
      --providers)
        (($# >= 2)) || fail "--providers requires a value"
        providers_file="$2"
        shift 2
        ;;
      --max-rounds)
        (($# >= 2)) || fail "--max-rounds requires a value"
        validate_max_rounds "$2"
        max_rounds_override="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        fail "unknown run option: $1"
        ;;
    esac
  done

  validate_config --cases "$cases_file" --providers "$providers_file" --rubric "$default_rubric" >/dev/null
  require_command "$gh_bin"
  require_command jq

  emit_case_provider_rows "$cases_file" "$providers_file" |
    while IFS= read -r record_json; do
      case_id="$(record_field "$record_json" '.case_id')"
      provider_id="$(record_field "$record_json" '.provider_id')"
      workflow_provider="$(record_field "$record_json" '.workflow_provider')"
      source_commit="$(record_field "$record_json" '.source_commit')"
      max_rounds="$(record_field "$record_json" '.max_rounds')"
      case_target_repo="$(resolve_target_repo "$record_json" "$target_repo")"
      case_target_ref="$(record_field "$record_json" '.target_ref')"
      target_sha="$(ensure_target_branch_contains_source "$case_target_repo" "$case_target_ref" "$source_commit" "$case_id")"
      issue_number="$(find_issue_number "$case_target_repo" "$case_id" "$provider_id")"
      [[ -n "$issue_number" ]] || fail "issue is missing for ${case_id}/${provider_id}; run create-issues first"
      rounds="${max_rounds_override:-$max_rounds}"
      if [[ "$dry_run" == true ]]; then
        printf 'would run %s@%s (%s) issue #%s provider=%s max_rounds=%s\n' "$case_target_repo" "$case_target_ref" "$target_sha" "$issue_number" "$workflow_provider" "$rounds"
      else
        "$gh_bin" workflow run agent-cycle.yml \
          --repo "$case_target_repo" \
          --ref "$case_target_ref" \
          -f "issue_number=${issue_number}" \
          -f "provider=${workflow_provider}" \
          -f "max_rounds=${rounds}" \
          -f "base_ref=${case_target_ref}" \
          -f "base_sha=${target_sha}"
        printf 'triggered %s/%s as issue #%s on %s@%s with provider=%s\n' "$case_id" "$provider_id" "$issue_number" "$case_target_repo" "$case_target_ref" "$workflow_provider"
      fi
    done
}

read_content_or_empty() {
  local target_repo="$1"
  local branch="$2"
  local path="$3"

  "$gh_bin" api "repos/${target_repo}/contents/${path}?ref=${branch}" --jq '.content' 2>/dev/null |
    ruby -rbase64 -e 'print Base64.decode64(STDIN.read)' 2>/dev/null || true
}

collect_results() {
  local target_repo=""
  local out_file=""

  cases_file="$default_cases"
  providers_file="$default_providers"
  while (($#)); do
    case "$1" in
      --target-repo)
        (($# >= 2)) || fail "--target-repo requires a value"
        target_repo="$2"
        shift 2
        ;;
      --cases)
        (($# >= 2)) || fail "--cases requires a value"
        cases_file="$2"
        shift 2
        ;;
      --providers)
        (($# >= 2)) || fail "--providers requires a value"
        providers_file="$2"
        shift 2
        ;;
      --out)
        (($# >= 2)) || fail "--out requires a value"
        out_file="$2"
        shift 2
        ;;
      *)
        fail "unknown collect option: $1"
        ;;
    esac
  done

  validate_config --cases "$cases_file" --providers "$providers_file" --rubric "$default_rubric" >/dev/null
  require_command "$gh_bin"
  require_command jq
  require_command ruby

  if [[ -n "$out_file" ]]; then
    : >"$out_file"
  fi

  emit_case_provider_rows "$cases_file" "$providers_file" |
    while IFS= read -r record_json; do
      case_id="$(record_field "$record_json" '.case_id')"
      provider_id="$(record_field "$record_json" '.provider_id')"
      workflow_provider="$(record_field "$record_json" '.workflow_provider')"
      case_target_repo="$(resolve_target_repo "$record_json" "$target_repo")"
      case_target_ref="$(record_field "$record_json" '.target_ref')"
      current_target_sha="$(target_branch_sha "$case_target_repo" "$case_target_ref" 2>/dev/null || true)"
      issue_number="$(find_issue_number "$case_target_repo" "$case_id" "$provider_id")"
      if [[ -z "$issue_number" ]]; then
        line="$(jq -cn \
          --arg case_id "$case_id" \
          --arg provider_id "$provider_id" \
          --arg target_repository "$case_target_repo" \
          --arg target_ref "$case_target_ref" \
          --arg current_target_sha "$current_target_sha" \
          --arg status "missing_issue" \
          '{case_id:$case_id, provider_id:$provider_id, target_repository:$target_repository, target_ref:$target_ref, target_sha:"", base_sha:"", current_target_sha:$current_target_sha, status:$status}')"
        if [[ -n "$out_file" ]]; then
          printf '%s\n' "$line" >>"$out_file"
        else
          printf '%s\n' "$line"
        fi
        continue
      fi

      branch="agent/issue-${issue_number}"
      state_json="$(read_content_or_empty "$case_target_repo" "$branch" ".agent_state/issues/${issue_number}/state.json")"
      result_json="$(read_content_or_empty "$case_target_repo" "$branch" ".agent_state/issues/${issue_number}/result.json")"
      verification_json="$(read_content_or_empty "$case_target_repo" "$branch" ".agent_state/issues/${issue_number}/verification.json")"
      pr_json="$("$gh_bin" pr list --repo "$case_target_repo" --head "$branch" --state all --json number,url,state,mergedAt --jq '.[0] // {}' 2>/dev/null || printf '{}')"
      empty_json="{}"
      state_json="${state_json:-$empty_json}"
      result_json="${result_json:-$empty_json}"
      verification_json="${verification_json:-$empty_json}"
      base_sha="$(jq -r '.base_sha // ""' <<<"$state_json")"

      line="$(jq -cn \
        --arg case_id "$case_id" \
        --arg provider_id "$provider_id" \
        --arg workflow_provider "$workflow_provider" \
        --arg target_repository "$case_target_repo" \
        --arg target_ref "$case_target_ref" \
        --arg target_sha "$base_sha" \
        --arg base_sha "$base_sha" \
        --arg current_target_sha "$current_target_sha" \
        --arg issue_number "$issue_number" \
        --argjson state "$state_json" \
        --argjson result "$result_json" \
        --argjson verification "$verification_json" \
        --argjson pr "$pr_json" \
        '{
          case_id: $case_id,
          provider_id: $provider_id,
          workflow_provider: $workflow_provider,
          target_repository: $target_repository,
          target_ref: $target_ref,
          target_sha: $target_sha,
          base_sha: $base_sha,
          current_target_sha: $current_target_sha,
          issue_number: ($issue_number | tonumber),
          status: ($result.status // $state.status // "unknown"),
          summary: ($result.summary // $state.last_summary // ""),
          round: ($state.round // 0),
          max_rounds: ($state.max_rounds // 0),
          run_url: ($state.last_run_url // ""),
          tests_count: (($result.tests // []) | length),
          findings: ($result.findings // []),
          verification_status: ($verification.status // "missing"),
          pr_url: ($pr.url // ""),
          pr_state: ($pr.state // "")
        }')"
      if [[ -n "$out_file" ]]; then
        printf '%s\n' "$line" >>"$out_file"
      else
        printf '%s\n' "$line"
      fi
    done
}

report_results() {
  local input_file=""
  local out_file=""

  rubric_file="$default_rubric"
  while (($#)); do
    case "$1" in
      --input)
        (($# >= 2)) || fail "--input requires a value"
        input_file="$2"
        shift 2
        ;;
      --rubric)
        (($# >= 2)) || fail "--rubric requires a value"
        rubric_file="$2"
        shift 2
        ;;
      --out)
        (($# >= 2)) || fail "--out requires a value"
        out_file="$2"
        shift 2
        ;;
      *)
        fail "unknown report option: $1"
        ;;
    esac
  done

  [[ -n "$input_file" ]] || fail "--input is required"
  require_command ruby
  report="$(ruby -rjson -ryaml - "$input_file" "$rubric_file" <<'RUBY'
input_path, rubric_path = ARGV
rows = File.readlines(input_path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
rubric_doc = YAML.load_file(rubric_path)
weights = rubric_doc.fetch("weights")
round_penalty = rubric_doc.fetch("round_penalty", 5).to_i
finding_penalties = rubric_doc.fetch("finding_penalties", {})

def finding_severity(finding)
  finding.to_s.split(":", 2).first.downcase
end

def score_row(row, weights, round_penalty, finding_penalties)
  score = 0
  complete = row["status"] == "complete"
  score += weights.fetch("completion").to_i if complete
  if complete
    round = [row["round"].to_i, 1].max
    score += [weights.fetch("rounds").to_i - ((round - 1) * round_penalty), 0].max
  end
  severities = Array(row["findings"]).map { |finding| finding_severity(finding) }
  change_score = weights.fetch("change_quality").to_i
  severities.each { |severity| change_score -= finding_penalties.fetch(severity, 0).to_i }
  score += [[change_score, weights.fetch("change_quality").to_i].min, 0].max
  score += weights.fetch("verification").to_i if row["verification_status"] == "pass"
  runtime_bad = row["status"].to_s.match?(/missing|unknown/) ||
    Array(row["findings"]).any? { |f| f.to_s.match?(/契约|credential|只读|protected|timeout|超时/i) }
  score += weights.fetch("stability").to_i unless runtime_bad
  score
end

scored = rows.map { |row| row.merge("score" => score_row(row, weights, round_penalty, finding_penalties)) }
providers = scored.group_by { |row| row.fetch("provider_id") }

puts "# Agent Benchmark Report"
puts
puts "| Provider | Cases | Avg score | Complete | Avg rounds | Runtime issues |"
puts "| --- | ---: | ---: | ---: | ---: | ---: |"
providers.sort.each do |provider, provider_rows|
  scores = provider_rows.map { |row| row.fetch("score") }
  complete = provider_rows.count { |row| row["status"] == "complete" }
  rounds = provider_rows.map { |row| row["round"].to_i }.reject(&:zero?)
  runtime_issues = provider_rows.count { |row| row["status"].to_s.match?(/missing|unknown/) }
  avg_score = scores.sum.to_f / scores.length
  avg_rounds = rounds.empty? ? 0 : rounds.sum.to_f / rounds.length
  puts "| #{provider} | #{provider_rows.length} | #{format('%.1f', avg_score)} | #{complete} | #{format('%.1f', avg_rounds)} | #{runtime_issues} |"
end

puts
puts "## Case Details"
puts
puts "| Case | Provider | Status | Score | Rounds | Verification | PR |"
puts "| --- | --- | --- | ---: | ---: | --- | --- |"
scored.sort_by { |row| [row["case_id"], row["provider_id"]] }.each do |row|
  pr = row["pr_url"].to_s.empty? ? "" : "[PR](#{row["pr_url"]})"
  puts "| #{row["case_id"]} | #{row["provider_id"]} | #{row["status"]} | #{row["score"]} | #{row["round"]}/#{row["max_rounds"]} | #{row["verification_status"]} | #{pr} |"
end
RUBY
)"

  if [[ -n "$out_file" ]]; then
    printf '%s\n' "$report" >"$out_file"
  else
    printf '%s\n' "$report"
  fi
}

command_name="${1:-help}"
if (($#)); then
  shift
fi

case "$command_name" in
  validate-config)
    validate_config "$@"
    ;;
  create-issues)
    create_issues "$@"
    ;;
  run)
    run_matrix "$@"
    ;;
  collect)
    collect_results "$@"
    ;;
  report)
    report_results "$@"
    ;;
  help | -h | --help)
    usage
    ;;
  *)
    fail "unknown benchmark command: ${command_name}; run 'agent-cycle benchmark help'"
    ;;
esac
