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

  grep -Fqx -- "$expected" "$file" || {
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
assert_contains "    types: [opened, reopened, edited, labeled]" "$default_listener"
assert_contains "    uses: dustPyrotechnic/agent-cycle-test/.github/workflows/reusable-agent-cycle.yml@v1" "$default_listener"
assert_contains "      engine_repository: dustPyrotechnic/agent-cycle-test" "$default_listener"
assert_contains "      engine_ref: v1" "$default_listener"

shortcut_target="${test_root}/shortcut"
make_target "$shortcut_target"
(
  cd "$shortcut_target"
  bash "${repo_root}/agent-cycle" deploy --dev --no-commit --local-only >/dev/null
)
shortcut_listener="${shortcut_target}/.github/workflows/agent-cycle.yml"
assert_contains "    uses: dustPyrotechnic/agent-cycle-test/.github/workflows/reusable-agent-cycle.yml@main" "$shortcut_listener"
assert_contains "      engine_ref: main" "$shortcut_listener"
assert_contains "      engine_token: \${{ secrets.ENGINE_TOKEN }}" "$shortcut_listener"

zero_arg_source="${test_root}/zero-arg-source"
zero_arg_target="${test_root}/zero-arg-target"
zero_arg_log="${test_root}/zero-arg.log"
mkdir -p "$zero_arg_source"
make_target "$zero_arg_target"
cp "${repo_root}/agent-cycle" "${zero_arg_source}/agent-cycle"
cat >"${zero_arg_source}/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_INSTALL_ARGS_LOG"
EOF
chmod +x "${zero_arg_source}/agent-cycle" "${zero_arg_source}/install.sh"
(
  cd "$zero_arg_target"
  FAKE_INSTALL_ARGS_LOG="$zero_arg_log" \
    /bin/bash "${zero_arg_source}/agent-cycle" deploy >/dev/null
)
assert_contains "--engine-repository" "$zero_arg_log"
assert_contains "dustPyrotechnic/agent-cycle-test" "$zero_arg_log"
assert_contains "--engine-ref" "$zero_arg_log"
assert_contains "v1" "$zero_arg_log"
assert_contains "--private-engine" "$zero_arg_log"
assert_contains "--commit" "$zero_arg_log"

progress_target="${test_root}/progress"
progress_log="${test_root}/progress.log"
make_target "$progress_target"
(
  cd "$progress_target"
  AGENT_PROGRESS=always bash "${repo_root}/install.sh" --local-only >"$progress_log"
)
grep -Fq "[############------------] 1/2 Inspect target repository" "$progress_log" || {
  echo "Interactive progress output did not render the halfway bar" >&2
  exit 1
}
grep -Fq "[########################] 2/2 Install listener workflow" "$progress_log" || {
  echo "Interactive progress output did not render the complete bar" >&2
  exit 1
}

plain_progress_target="${test_root}/plain-progress"
plain_progress_log="${test_root}/plain-progress.log"
make_target "$plain_progress_target"
(
  cd "$plain_progress_target"
  bash "${repo_root}/install.sh" --local-only >"$plain_progress_log"
)
grep -Fq "==> [1/2] Inspect target repository" "$plain_progress_log" || {
  echo "Non-interactive progress output did not use stable step logs" >&2
  exit 1
}
if grep -Fq -- "------------" "$plain_progress_log"; then
  echo "Non-interactive progress output unexpectedly rendered a progress bar" >&2
  exit 1
fi

disabled_progress_target="${test_root}/disabled-progress"
disabled_progress_log="${test_root}/disabled-progress.log"
make_target "$disabled_progress_target"
(
  cd "$disabled_progress_target"
  AGENT_PROGRESS=always bash "${repo_root}/install.sh" --local-only --no-progress >"$disabled_progress_log"
)
if grep -Fq -- "------------" "$disabled_progress_log"; then
  echo "--no-progress did not disable the forced progress bar" >&2
  exit 1
fi

visibility_target="${test_root}/visibility-target"
visibility_bin="${test_root}/visibility-bin"
visibility_log="${test_root}/visibility.log"
make_target "$visibility_target"
mkdir -p "$visibility_bin"
cat >"${visibility_bin}/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status")
    exit 0
    ;;
  "repo view")
    printf '%s\n' "example/public-target ADMIN false"
    ;;
  "api repos/example/private-engine")
    printf '%s\n' "true"
    ;;
  *)
    echo "Unexpected fake gh invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${visibility_bin}/gh"
if (
  cd "$visibility_target"
  BASH_ENV=/dev/null \
  PATH="${visibility_bin}:$PATH" \
    bash "${repo_root}/install.sh" \
      --engine-repository example/private-engine \
      --private-engine \
      --skip-secret-check >"$visibility_log" 2>&1
); then
  echo "Installer unexpectedly allowed a public target to call a private engine" >&2
  exit 1
fi
grep -Fq "public target example/public-target cannot call reusable workflows from private engine example/private-engine" "$visibility_log" || {
  echo "Installer did not explain the public-target/private-engine incompatibility" >&2
  cat "$visibility_log" >&2
  exit 1
}

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

remote_source="${test_root}/remote-source"
remote_target="${test_root}/remote-target"
remote_bin="${test_root}/remote-bin"
mkdir -p "$remote_source" "$remote_bin"
cp "${repo_root}/install.sh" "${remote_source}/install.sh"
make_target "$remote_target"
cat >"${remote_bin}/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
cat >"${remote_bin}/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *repos/*/contents/install.sh*)
    cat "$FAKE_INSTALLER"
    ;;
  *repos/*/contents/templates/agent-cycle-listener.yml*)
    cat "$FAKE_LISTENER_TEMPLATE"
    ;;
  *)
    echo "Unexpected fake gh invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${remote_bin}/curl" "${remote_bin}/gh"
(
  cd "$remote_target"
  PATH="${remote_bin}:$PATH" \
    FAKE_LISTENER_TEMPLATE="${repo_root}/templates/agent-cycle-listener.yml" \
    bash "${remote_source}/install.sh" --engine-ref main --local-only >/dev/null 2>&1
)
remote_listener="${remote_target}/.github/workflows/agent-cycle.yml"
assert_contains "    uses: dustPyrotechnic/agent-cycle-test/.github/workflows/reusable-agent-cycle.yml@main" "$remote_listener"
assert_contains "      engine_ref: main" "$remote_listener"

shortcut_bin="${test_root}/shortcut-bin"
AGENT_CYCLE_BIN_DIR="$shortcut_bin" bash "${repo_root}/agent-cycle" setup >/dev/null
[[ -x "${shortcut_bin}/agent-cycle" ]] || {
  echo "Shortcut setup did not install an executable command" >&2
  exit 1
}
[[ -x "${shortcut_bin}/agent-cycle-install.sh" ]] || {
  echo "Shortcut setup did not install the bundled deployer" >&2
  exit 1
}

remote_shortcut_target="${test_root}/remote-shortcut-target"
make_target "$remote_shortcut_target"
(
  cd "$remote_shortcut_target"
  PATH="${remote_bin}:$PATH" \
    FAKE_INSTALLER="${repo_root}/install.sh" \
    FAKE_LISTENER_TEMPLATE="${repo_root}/templates/agent-cycle-listener.yml" \
    "${shortcut_bin}/agent-cycle" deploy --dev --no-commit --local-only >/dev/null 2>&1
)
remote_shortcut_listener="${remote_shortcut_target}/.github/workflows/agent-cycle.yml"
assert_contains "    uses: dustPyrotechnic/agent-cycle-test/.github/workflows/reusable-agent-cycle.yml@main" "$remote_shortcut_listener"
assert_contains "      engine_token: \${{ secrets.ENGINE_TOKEN }}" "$remote_shortcut_listener"

standalone_shortcut_bin="${test_root}/standalone-shortcut-bin"
standalone_shortcut_target="${test_root}/standalone-shortcut-target"
mkdir -p "$standalone_shortcut_bin"
cp "${repo_root}/agent-cycle" "${standalone_shortcut_bin}/agent-cycle"
chmod +x "${standalone_shortcut_bin}/agent-cycle"
make_target "$standalone_shortcut_target"
(
  cd "$standalone_shortcut_target"
  BASH_ENV=/dev/null \
    PATH="${remote_bin}:$PATH" \
    FAKE_INSTALLER="${repo_root}/install.sh" \
    FAKE_LISTENER_TEMPLATE="${repo_root}/templates/agent-cycle-listener.yml" \
    "${standalone_shortcut_bin}/agent-cycle" deploy --dev --no-commit --local-only >/dev/null 2>&1
)
standalone_shortcut_listener="${standalone_shortcut_target}/.github/workflows/agent-cycle.yml"
assert_contains "    uses: dustPyrotechnic/agent-cycle-test/.github/workflows/reusable-agent-cycle.yml@main" "$standalone_shortcut_listener"

release_target="${test_root}/release-target"
release_bin="${test_root}/release-bin"
release_log="${test_root}/release.log"
make_target "$release_target"
mkdir -p "$release_bin"
(
  cd "$release_target"
  git config user.name test
  git config user.email test@example.com
  git commit --allow-empty -q -m initial
  git tag v1
)
cat >"${release_bin}/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "release view")
    exit 0
    ;;
  "release delete")
    printf '%s\n' "$*" >>"$FAKE_RELEASE_LOG"
    ;;
  "repo view")
    printf '%s\n' "$FAKE_ENGINE_REPOSITORY"
    ;;
  *)
    echo "Unexpected fake gh invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${release_bin}/gh"
if (
  cd "$release_target"
  BASH_ENV=/dev/null \
    PATH="${release_bin}:$PATH" \
    AGENT_ENGINE_REPOSITORY=example/custom-engine \
    bash "${repo_root}/agent-cycle" cancel-release v1 >/dev/null 2>&1
); then
  echo "cancel-release unexpectedly ran without --yes" >&2
  exit 1
fi
(
  cd "$release_target"
  BASH_ENV=/dev/null \
    PATH="${release_bin}:$PATH" \
    AGENT_ENGINE_REPOSITORY=example/custom-engine \
    FAKE_ENGINE_REPOSITORY=example/custom-engine \
    FAKE_RELEASE_LOG="$release_log" \
    bash "${repo_root}/agent-cycle" cancel-release v1 --yes >/dev/null
)
assert_contains "release delete v1 --repo example/custom-engine --cleanup-tag --yes" "$release_log"
if git -C "$release_target" show-ref --verify --quiet refs/tags/v1; then
  echo "cancel-release did not delete the matching local tag" >&2
  exit 1
fi

echo "Installer tests passed"
