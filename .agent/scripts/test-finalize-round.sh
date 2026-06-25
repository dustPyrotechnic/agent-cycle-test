#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

origin="${test_root}/origin.git"
target="${test_root}/target"
engine="${test_root}/engine"
bin_dir="${test_root}/bin"
gh_log="${test_root}/gh.log"

mkdir -p "$engine/scripts" "$bin_dir"
git init -q --bare "$origin"
git clone -q "$origin" "$target"
mkdir -p "$target/.agent_state/issues/1"
git -C "$target" checkout -q -b agent/issue-1
printf 'change\n' >"${target}/app.txt"
git -C "$target" add app.txt
git -C "$target" -c user.name=test -c user.email=test@example.com commit -qm init
git -C "$target" push -q origin agent/issue-1

base_sha="0123456789abcdef0123456789abcdef01234567"
cat >"${target}/.agent_state/issues/1/state.json" <<EOF
{"issue":1,"round":1,"max_rounds":3,"base_ref":"benchmark-base","base_sha":"${base_sha}","provider":"deepseek","status":"running"}
EOF
cat >"${target}/.agent_state/issues/1/result.json" <<'EOF'
{"status":"complete","summary":"Done","next_step":"Review","tests":["unit: passed"],"findings":[]}
EOF
cat >"${engine}/scripts/validate-target.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${engine}/scripts/validate-target.sh"

cat >"${bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  "api repos/owner/repo --jq .default_branch")
    printf 'main\n'
    ;;
  "api repos/owner/repo/git/ref/heads/benchmark-base --jq .object.sha")
    printf '%s\n' "$BASE_SHA"
    ;;
  "pr list --head agent/issue-1 --state open --json url --jq .[0].url // empty")
    exit 0
    ;;
  pr\ create*)
    printf 'https://example.test/pr/1\n'
    ;;
  issue\ comment*|issue\ edit*)
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
  GH_LOG="$gh_log" \
  BASE_SHA="$base_sha" \
  TARGET_ROOT="$target" \
  ENGINE_ROOT="$engine" \
  AGENT_PROVIDER=deepseek \
  bash "${repo_root}/.agent/scripts/finalize-round.sh" >/dev/null

grep -q -- "pr create --base benchmark-base --head agent/issue-1" "$gh_log"
grep -q 'client_payload\[base_ref\]=${pr_base_ref}' "${repo_root}/.agent/scripts/finalize-round.sh"
grep -q 'client_payload\[base_sha\]=${pr_base_sha}' "${repo_root}/.agent/scripts/finalize-round.sh"

origin_moved="${test_root}/origin-moved.git"
target_moved="${test_root}/target-moved"
gh_log_moved="${test_root}/gh-moved.log"
git init -q --bare "$origin_moved"
git clone -q "$origin_moved" "$target_moved"
git -C "$target_moved" checkout -q -b agent/issue-2
mkdir -p "${target_moved}/.agent_state/issues/2"
printf 'change\n' >"${target_moved}/app.txt"
cat >"${target_moved}/.agent_state/issues/2/state.json" <<'EOF'
{"issue":2,"round":1,"max_rounds":3,"base_ref":"benchmark-base","base_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider":"deepseek","status":"running"}
EOF
cat >"${target_moved}/.agent_state/issues/2/result.json" <<'EOF'
{"status":"complete","summary":"Done","next_step":"Review","tests":["unit: passed"],"findings":[]}
EOF
git -C "$target_moved" add .
git -C "$target_moved" -c user.name=test -c user.email=test@example.com commit -qm init
git -C "$target_moved" push -q origin agent/issue-2

PATH="${bin_dir}:$PATH" \
  ISSUE_NUMBER=2 \
  GITHUB_REPOSITORY=owner/repo \
  GH_BIN="${bin_dir}/gh" \
  GH_LOG="$gh_log_moved" \
  BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  TARGET_ROOT="$target_moved" \
  ENGINE_ROOT="$engine" \
  AGENT_PROVIDER=deepseek \
  bash "${repo_root}/.agent/scripts/finalize-round.sh" >/dev/null

if grep -q -- "pr create" "$gh_log_moved"; then
  echo "Finalize created a PR even though benchmark base moved" >&2
  exit 1
fi
test "$(git --git-dir="$origin_moved" show agent/issue-2:.agent_state/issues/2/result.json | jq -r '.status')" = "blocked"
git --git-dir="$origin_moved" show agent/issue-2:.agent_state/issues/2/result.json |
  grep -q "benchmark base ref benchmark-base moved"

# Scenario 3: API failure — gh returns empty for SHA lookup → must NOT block
origin_apifail="${test_root}/origin-apifail.git"
target_apifail="${test_root}/target-apifail"
gh_log_apifail="${test_root}/gh-apifail.log"
git init -q --bare "$origin_apifail"
git clone -q "$origin_apifail" "$target_apifail"
git -C "$target_apifail" checkout -q -b agent/issue-3
mkdir -p "${target_apifail}/.agent_state/issues/3"
printf 'change\n' >"${target_apifail}/app.txt"
cat >"${target_apifail}/.agent_state/issues/3/state.json" <<EOF
{"issue":3,"round":1,"max_rounds":3,"base_ref":"benchmark-base","base_sha":"${base_sha}","provider":"deepseek","status":"running"}
EOF
cat >"${target_apifail}/.agent_state/issues/3/result.json" <<'EOF'
{"status":"complete","summary":"Done","next_step":"Review","tests":["unit: passed"],"findings":[]}
EOF
git -C "$target_apifail" add .
git -C "$target_apifail" -c user.name=test -c user.email=test@example.com commit -qm init
git -C "$target_apifail" push -q origin agent/issue-3

cat >"${bin_dir}/gh-apifail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  "api repos/owner/repo --jq .default_branch")
    printf 'main\n'
    ;;
  "api repos/owner/repo/git/ref/heads/benchmark-base --jq .object.sha")
    exit 1
    ;;
  "pr list --head agent/issue-3 --state open --json url --jq .[0].url // empty")
    exit 0
    ;;
  pr\ create*)
    printf 'https://example.test/pr/3\n'
    ;;
  issue\ comment*|issue\ edit*)
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${bin_dir}/gh-apifail"

PATH="${bin_dir}:$PATH" \
  ISSUE_NUMBER=3 \
  GITHUB_REPOSITORY=owner/repo \
  GH_BIN="${bin_dir}/gh-apifail" \
  GH_LOG="$gh_log_apifail" \
  BASE_SHA="$base_sha" \
  TARGET_ROOT="$target_apifail" \
  ENGINE_ROOT="$engine" \
  AGENT_PROVIDER=deepseek \
  bash "${repo_root}/.agent/scripts/finalize-round.sh" >/dev/null

result_status="$(git --git-dir="$origin_apifail" show agent/issue-3:.agent_state/issues/3/result.json | jq -r '.status')"
if [[ "$result_status" == "blocked" ]]; then
  echo "API failure incorrectly caused blocked status (F1 not fixed)" >&2
  exit 1
fi
grep -q -- "pr create" "$gh_log_apifail" || {
  echo "PR was not created after API failure (F1 regression)" >&2
  exit 1
}

echo "Finalize round tests passed"
