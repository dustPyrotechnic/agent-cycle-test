#!/usr/bin/env bash
set -euo pipefail

# Validates the target repository after an agent round. It must succeed on an
# arbitrary repository, so it never requires the central engine's memory layout
# or module structure.
#
# SECURITY: this script runs during finalization, which holds the privileged
# GITHUB_TOKEN and the Actions command-file environment. It therefore performs
# ONLY static checks and never executes target-controlled code (no project
# hooks, build scripts, or Makefiles). Model-influenced target code must never
# run with the token; project validation is the agent's responsibility during
# the round, where Claude Code receives no GitHub token, PAT, or Actions runtime
# credentials.

TARGET_ROOT="${TARGET_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$TARGET_ROOT"

# NOTE: byte-for-byte parity between CLAUDE.md and AGENTS.md is an ENGINE-specific
# convention enforced in validate-engine.sh. Target repositories own their own
# instruction files and may keep them intentionally different, so this validator
# must not impose that rule on arbitrary targets.

# Workflow files the agent may have touched must still parse as YAML.
if command -v ruby >/dev/null 2>&1; then
  shopt -s nullglob
  workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
  if ((${#workflow_files[@]})); then
    ruby -e 'require "yaml"; ARGV.each { |file| YAML.parse_file(file) }' "${workflow_files[@]}"
  fi
fi

echo "Target repository validation passed"
