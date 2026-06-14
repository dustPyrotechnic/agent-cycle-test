#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible entry point. Engine integrity now lives in
# validate-engine.sh; target-repository checks live in validate-target.sh.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${script_dir}/validate-engine.sh" "$@"
