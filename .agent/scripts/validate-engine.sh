#!/usr/bin/env bash
set -euo pipefail

# Validates the central engine repository itself: shell and YAML syntax,
# synchronized root instructions, required module memory, and the reusable
# workflow plus listener template that target repositories depend on.
# A failure here must block engine releases. This is NOT run against target
# repositories; see validate-target.sh for that.

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

for script in .agent/scripts/*.sh; do
  bash -n "$script"
done
bash -n install.sh
bash -n agent-cycle

cmp -s CLAUDE.md AGENTS.md || {
  echo "CLAUDE.md and AGENTS.md must remain byte-for-byte identical" >&2
  exit 1
}

required_files=(
  memory.md
  .agent/memory.md
  .agent/prompts/memory.md
  .agent/prompts/agent-round.md
  .agent/prompts/analyst-system.md
  .agent/prompts/implementer-system.md
  .agent/prompts/verifier-system.md
  .agent/prompts/reviewer-system.md
  .agent/scripts/memory.md
  .agent/scripts/benchmark.sh
  .agent/scripts/test-prepare-round.sh
  .agent/scripts/test-finalize-round.sh
  .agent/scripts/test-installer.sh
  .agent/scripts/test-benchmark.sh
  .agent/scripts/test-specialized-pipeline.sh
  .agent/skills/memory.md
  .agent/skills/task-analysis/SKILL.md
  .agent/skills/systematic-debugging/SKILL.md
  .agent/skills/test-driven-change/SKILL.md
  .agent/skills/regression-verification/SKILL.md
  .agent/skills/evidence-based-review/SKILL.md
  .agent_state/memory.md
  .github/memory.md
  .github/workflows/memory.md
  .github/ISSUE_TEMPLATE/memory.md
  templates/memory.md
  install.sh
  agent-cycle
  benchmarks/cases.yml
  benchmarks/providers.yml
  benchmarks/rubric.yml
  docs/benchmarking.md
  .github/workflows/reusable-agent-cycle.yml
  templates/agent-cycle-listener.yml
)
for file in "${required_files[@]}"; do
  [[ -s "$file" ]] || {
    echo "Required engine file is missing or empty: $file" >&2
    exit 1
  }
done

# ISSUE_TEMPLATE may legitimately hold no YAML templates; expand globs with
# nullglob so an empty directory does not pass a literal pattern to Ruby.
shopt -s nullglob
yaml_files=(.github/workflows/*.yml .github/ISSUE_TEMPLATE/*.yml templates/*.yml)
shopt -u nullglob
ruby -e 'require "yaml"; ARGV.each { |file| YAML.parse_file(file) }' "${yaml_files[@]}"

ruby -e '
  require "yaml"
  workflow = YAML.load_file(".github/workflows/reusable-agent-cycle.yml")
  job = workflow.fetch("jobs").fetch("cycle")
  abort "GH_TOKEN must not be defined at reusable workflow job scope" if job.fetch("env", {}).key?("GH_TOKEN")
  agent = job.fetch("steps").find { |step| step["name"] == "Run Claude Code round" }
  abort "Run Claude Code round step is missing" unless agent
  abort "GH_TOKEN must not be available to the model step" if agent.fetch("env", {}).key?("GH_TOKEN")
'

bash .agent/scripts/test-specialized-pipeline.sh
bash .agent/scripts/test-prepare-round.sh
bash .agent/scripts/test-finalize-round.sh
bash .agent/scripts/test-installer.sh
bash .agent/scripts/test-benchmark.sh

echo "Central engine configuration is valid"
