#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

seed="${test_root}/seed"
origin="${test_root}/origin.git"
target="${test_root}/target"
bin_dir="${test_root}/bin"

mkdir -p "$seed" "$bin_dir"
git init -q "$seed"
git -C "$seed" checkout -q -b main
printf 'main\n' >"${seed}/app.txt"
git -C "$seed" add app.txt
git -C "$seed" -c user.name=test -c user.email=test@example.com commit -qm main
git -C "$seed" checkout -q -b benchmark-base
printf 'benchmark-base\n' >"${seed}/app.txt"
git -C "$seed" add app.txt
git -C "$seed" -c user.name=test -c user.email=test@example.com commit -qm benchmark-base
benchmark_sha="$(git -C "$seed" rev-parse HEAD)"
git -C "$seed" checkout -q main
git clone -q --bare "$seed" "$origin"
git clone -q "$origin" "$target"

cat >"${bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "api repos/owner/repo/issues/1")
    printf '%s\n' '{"number":1,"title":"Benchmark task","html_url":"https://example.test/issues/1","author_association":"OWNER","labels":[{"name":"agent-benchmark"}],"body":"Run benchmark."}'
    ;;
  "api repos/owner/repo --jq .default_branch")
    printf 'main\n'
    ;;
  label\ create*|issue\ edit*)
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${bin_dir}/gh"

PATH="${bin_dir}:$PATH" \
  ISSUE_NUMBER=1 \
  GITHUB_REPOSITORY=owner/repo \
  GH_BIN="${bin_dir}/gh" \
  TARGET_ROOT="$target" \
  ENGINE_ROOT="${repo_root}/.agent" \
  MAX_ROUNDS=1 \
  AGENT_PROVIDER=deepseek \
  AGENT_BASE_REF=benchmark-base \
  AGENT_BASE_SHA="$benchmark_sha" \
  bash "${repo_root}/.agent/scripts/prepare-round.sh" >/dev/null

test "$(git -C "$target" branch --show-current)" = "agent/issue-1"
grep -q '^benchmark-base$' "${target}/app.txt"
test "$(jq -r '.base_ref' "${target}/.agent_state/issues/1/state.json")" = "benchmark-base"
test "$(jq -r '.base_sha' "${target}/.agent_state/issues/1/state.json")" = "$benchmark_sha"
git -C "$origin" show-ref --verify --quiet refs/heads/agent/issue-1

git -C "$origin" update-ref -d refs/heads/benchmark-base
PATH="${bin_dir}:$PATH" \
  ISSUE_NUMBER=1 \
  GITHUB_REPOSITORY=owner/repo \
  GH_BIN="${bin_dir}/gh" \
  TARGET_ROOT="$target" \
  ENGINE_ROOT="${repo_root}/.agent" \
  MAX_ROUNDS=2 \
  AGENT_PROVIDER=deepseek \
  AGENT_BASE_REF=benchmark-base \
  AGENT_BASE_SHA="$benchmark_sha" \
  bash "${repo_root}/.agent/scripts/prepare-round.sh" >/dev/null

test "$(git -C "$target" branch --show-current)" = "agent/issue-1"
grep -q '^benchmark-base$' "${target}/app.txt"
test "$(jq -r '.round' "${target}/.agent_state/issues/1/state.json")" = "2"
test "$(jq -r '.base_ref' "${target}/.agent_state/issues/1/state.json")" = "benchmark-base"
test "$(jq -r '.base_sha' "${target}/.agent_state/issues/1/state.json")" = "$benchmark_sha"

PATH="${bin_dir}:$PATH" \
  ISSUE_NUMBER=1 \
  GITHUB_REPOSITORY=owner/repo \
  GH_BIN="${bin_dir}/gh" \
  TARGET_ROOT="$target" \
  ENGINE_ROOT="${repo_root}/.agent" \
  MAX_ROUNDS=3 \
  AGENT_PROVIDER=deepseek \
  bash "${repo_root}/.agent/scripts/prepare-round.sh" >/dev/null

test "$(git -C "$target" branch --show-current)" = "agent/issue-1"
test "$(jq -r '.round' "${target}/.agent_state/issues/1/state.json")" = "3"
test "$(jq -r '.base_ref' "${target}/.agent_state/issues/1/state.json")" = "benchmark-base"
test "$(jq -r '.base_sha' "${target}/.agent_state/issues/1/state.json")" = "$benchmark_sha"

set +e
PATH="${bin_dir}:$PATH" \
  ISSUE_NUMBER=1 \
  GITHUB_REPOSITORY=owner/repo \
  GH_BIN="${bin_dir}/gh" \
  TARGET_ROOT="$target" \
  ENGINE_ROOT="${repo_root}/.agent" \
  MAX_ROUNDS=4 \
  AGENT_PROVIDER=deepseek \
  AGENT_BASE_REF=main \
  bash "${repo_root}/.agent/scripts/prepare-round.sh" >"${test_root}/base-mismatch.out" 2>"${test_root}/base-mismatch.err"
base_mismatch_status=$?
set -e
test "$base_mismatch_status" -ne 0
grep -q "refusing to rerun" "${test_root}/base-mismatch.err"
test "$(jq -r '.round' "${target}/.agent_state/issues/1/state.json")" = "3"
test "$(jq -r '.base_ref' "${target}/.agent_state/issues/1/state.json")" = "benchmark-base"
test "$(jq -r '.base_sha' "${target}/.agent_state/issues/1/state.json")" = "$benchmark_sha"

echo "Prepare round tests passed"
