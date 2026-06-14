#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

make_target() {
  local target="$1"

  git init -q "$target"
}

assert_contains() {
  local expected="$1"
  local file="$2"

  grep -Fqx "$expected" "$file" || {
    echo "Expected line not found in ${file}: ${expected}" >&2
    exit 1
  }
}

default_target="${test_root}/default"
make_target "$default_target"
(
  cd "$default_target"
  bash "${repo_root}/install.sh" --local-only >/dev/null
)
default_listener="${default_target}/.github/workflows/agent-cycle.yml"
assert_contains "    uses: dustPyrotechnic/agent-cycle-test/.github/workflows/reusable-agent-cycle.yml@v1" "$default_listener"
assert_contains "      engine_repository: dustPyrotechnic/agent-cycle-test" "$default_listener"
assert_contains "      engine_ref: v1" "$default_listener"

custom_target="${test_root}/custom"
make_target "$custom_target"
(
  cd "$custom_target"
  bash "${repo_root}/install.sh" \
    --local-only \
    --engine-repository example/custom-engine \
    --engine-ref release-2 \
    --provider mimo \
    --private-engine >/dev/null
)
custom_listener="${custom_target}/.github/workflows/agent-cycle.yml"
assert_contains "        default: mimo" "$custom_listener"
assert_contains "    uses: example/custom-engine/.github/workflows/reusable-agent-cycle.yml@release-2" "$custom_listener"
assert_contains "      provider: \${{ github.event.client_payload.provider || inputs.provider || 'mimo' }}" "$custom_listener"
assert_contains "      engine_repository: example/custom-engine" "$custom_listener"
assert_contains "      engine_ref: release-2" "$custom_listener"
assert_contains "      engine_token: \${{ secrets.ENGINE_TOKEN }}" "$custom_listener"

collision_target="${test_root}/collision"
make_target "$collision_target"
mkdir -p "${collision_target}/.github/workflows"
printf 'existing workflow\n' >"${collision_target}/.github/workflows/agent-cycle.yml"
if (
  cd "$collision_target"
  bash "${repo_root}/install.sh" --local-only >/dev/null 2>&1
); then
  echo "Installer unexpectedly replaced an existing listener without --force" >&2
  exit 1
fi
assert_contains "existing workflow" "${collision_target}/.github/workflows/agent-cycle.yml"

for listener in "$default_listener" "$custom_listener"; do
  ruby -e 'require "yaml"; YAML.parse_file(ARGV.fetch(0))' "$listener"
done

echo "Installer tests passed"
