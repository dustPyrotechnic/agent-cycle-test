#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

for script in .agent/scripts/*.sh; do
  bash -n "$script"
done

cmp -s CLAUDE.md AGENTS.md || {
  echo "CLAUDE.md and AGENTS.md must remain byte-for-byte identical" >&2
  exit 1
}

required_memory=(
  memory.md
  .agent/memory.md
  .agent/prompts/memory.md
  .agent/scripts/memory.md
  .agent_state/memory.md
  .github/memory.md
  .github/workflows/memory.md
  .github/ISSUE_TEMPLATE/memory.md
)
for file in "${required_memory[@]}"; do
  [[ -s "$file" ]] || {
    echo "Required progressive-disclosure memory is missing: $file" >&2
    exit 1
  }
done

ruby -e 'require "yaml"; ARGV.each { |file| YAML.parse_file(file) }' .github/workflows/*.yml .github/ISSUE_TEMPLATE/*.yml

echo "Repository agent configuration is valid"
