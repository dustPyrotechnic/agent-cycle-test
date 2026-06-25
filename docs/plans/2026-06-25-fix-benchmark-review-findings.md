# Benchmark Review Findings Fix Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 8 confirmed/plausible bugs found in the benchmark base-SHA feature code review.

**Architecture:** All fixes are localised to three shell scripts (`finalize-round.sh`, `prepare-round.sh`, `agent-cycle`) and a git staging operation for untracked files. No new abstractions — each fix is the minimal guard or correction at the exact faulty line.

**Tech Stack:** Bash, jq, git, GitHub CLI (`gh`)

---

## Finding Summary

| # | Severity | File | Issue |
|---|----------|------|-------|
| F1 | Critical | `finalize-round.sh:137` | API failure → `current_pr_base_sha=""` → false-positive drift block |
| F2 | High | `validate-engine.sh:34` | 8 required files not in git; every fresh clone fails validation |
| F3 | High | `finalize-round.sh:198` | `git push` runs even when `git commit` was skipped in publish_state_changes path |
| F4 | Medium | `agent-cycle:71` | `AGENT_BENCHMARK_*_FILE` set to `""` (empty string) when local path exists |
| F5 | Medium | `prepare-round.sh:66` | `git fetch origin <sha>` fails silently on non-existent SHA; no diagnostic |
| F6 | Medium | `agent-cycle:55` | `benchmark()` overwrites any prior EXIT trap without restoring it |
| F7 | Low | `prepare-round.sh:70` | `FETCH_HEAD` used as checkout ref — race window between fetch and checkout |
| F8 | Low | `prepare-round.sh:102` | Mixed tabs/spaces in jq block |

---

## Task 1: Fix F1 — Drift check false-positive on API failure

**Files:**
- Modify: `.agent/scripts/finalize-round.sh:137`
- Modify: `.agent/scripts/test-finalize-round.sh` (add API-failure test case)

The bug is on line 137. When `gh api` fails and `|| true` suppresses it,
`current_pr_base_sha` is `""`. The comparison `"" != "$pr_base_sha"` is true,
so a valid run is permanently blocked.

**Step 1: Add the guard in finalize-round.sh**

Change line 137 from:
```bash
  if [[ "$current_pr_base_sha" != "$pr_base_sha" ]]; then
```
to:
```bash
  if [[ -n "$current_pr_base_sha" && "$current_pr_base_sha" != "$pr_base_sha" ]]; then
```

**Step 2: Extend test-finalize-round.sh with API-failure scenario**

Append a third test scenario to `test-finalize-round.sh` (after line 115, before the final `echo`):

```bash
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

# Override gh stub: SHA lookup returns empty (simulates API failure with || true)
cat >"${bin_dir}/gh-apifail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  "api repos/owner/repo --jq .default_branch")
    printf 'main\n'
    ;;
  "api repos/owner/repo/git/ref/heads/benchmark-base --jq .object.sha")
    exit 1   # simulates API error; finalize-round.sh uses || true so empty result
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

# Must NOT be blocked — API failure should be treated as "unknown, skip drift check"
result_status="$(git --git-dir="$origin_apifail" show agent/issue-3:.agent_state/issues/3/result.json | jq -r '.status')"
if [[ "$result_status" == "blocked" ]]; then
  echo "API failure incorrectly caused blocked status (F1 not fixed)" >&2
  exit 1
fi
# PR must have been created (run proceeded normally)
grep -q -- "pr create" "$gh_log_apifail" || {
  echo "PR was not created after API failure (F1 not fixed)" >&2
  exit 1
}
```

**Step 3: Run test to verify F1 is fixed**

```bash
cd /Users/pyrotechnic/Downloads/自己的东西/自己的项目/agent-cycle-test
bash .agent/scripts/test-finalize-round.sh
```
Expected: `Finalize round tests passed`

---

## Task 2: Fix F3 — git push runs even when commit skipped (publish_state_changes path)

**Files:**
- Modify: `.agent/scripts/finalize-round.sh:194-199`

The `publish_state_changes == "true"` block (lines 193–199) has `git push` outside the commit guard:

```bash
  if [[ "$publish_state_changes" == "true" ]]; then
    git add "$STATE_DIR"
    if ! git diff --cached --quiet; then
      git commit -m "agent: issue #${ISSUE_NUMBER} round ${round} (${status})"
    fi
    git push --set-upstream origin "$branch"   # ← always runs
```

Fix: move `git push` inside the commit guard:

```bash
  if [[ "$publish_state_changes" == "true" ]]; then
    git add "$STATE_DIR"
    if ! git diff --cached --quiet; then
      git commit -m "agent: issue #${ISSUE_NUMBER} round ${round} (${status})"
      git push --set-upstream origin "$branch"
    fi
```

**Step 1: Apply the fix**

In `.agent/scripts/finalize-round.sh`, restructure lines 193–199 as shown above.

**Step 2: Verify with existing test**

The existing drift-detection test (scenario 2 in `test-finalize-round.sh`) exercises the `publish_state_changes` path. After this fix, re-run:

```bash
bash .agent/scripts/test-finalize-round.sh
```
Expected: `Finalize round tests passed` (the scenario 2 push is still covered because state files differ from the initial commit).

---

## Task 3: Fix F7 — FETCH_HEAD race in prepare-round.sh

**Files:**
- Modify: `.agent/scripts/prepare-round.sh:70`

Line 70 sets `base_checkout_ref="FETCH_HEAD"` (a symbolic name). If anything updates `FETCH_HEAD` between this line and the `git checkout` on line 75, the branch is silently created from the wrong commit.

**Step 1: Resolve FETCH_HEAD immediately after fetch**

Change line 70 from:
```bash
    base_checkout_ref="FETCH_HEAD"
```
to:
```bash
    base_checkout_ref="$(git rev-parse FETCH_HEAD)"
```

**Step 2: Run existing prepare-round test**

```bash
bash .agent/scripts/test-prepare-round.sh
```
Expected: `Prepare round tests passed`

---

## Task 4: Fix F5 — Silent abort on git fetch by SHA failure

**Files:**
- Modify: `.agent/scripts/prepare-round.sh:65-67`

When `git fetch origin "$AGENT_BASE_SHA"` fails (SHA not in remote), `set -euo pipefail` aborts with no diagnostic. Add an explicit error message before the fetch:

**Step 1: Wrap the SHA fetch with an error hint**

Change:
```bash
  if [[ -n "$AGENT_BASE_SHA" ]]; then
    git fetch origin "$AGENT_BASE_SHA"
    base_checkout_ref="$AGENT_BASE_SHA"
```
to:
```bash
  if [[ -n "$AGENT_BASE_SHA" ]]; then
    git fetch origin "$AGENT_BASE_SHA" || {
      echo "Failed to fetch base SHA ${AGENT_BASE_SHA} from origin. Ensure the commit is reachable on the remote." >&2
      exit 1
    }
    base_checkout_ref="$AGENT_BASE_SHA"
```

**Step 2: Run test**

```bash
bash .agent/scripts/test-prepare-round.sh
```
Expected: `Prepare round tests passed`

---

## Task 5: Fix F8 — Mixed tabs/spaces in prepare-round.sh jq block

**Files:**
- Modify: `.agent/scripts/prepare-round.sh:101-116`

The `if [[ -f "${STATE_DIR}/state.json" ]]` branch (lines 101–116) uses leading tabs while the rest of the file uses spaces. Normalise to spaces.

**Step 1: Re-indent the block to spaces**

The corrected block should be (2-space indent throughout, matching the file's style):

```bash
if [[ -f "${STATE_DIR}/state.json" ]]; then
  jq \
    --argjson round "$next_round" \
    --argjson max_rounds "$MAX_ROUNDS" \
    --arg base_ref "$base_ref_label" \
    --arg base_sha "$base_sha_label" \
    --arg provider "$AGENT_PROVIDER" \
    --arg now "$now" \
    '.round = $round
     | .max_rounds = $max_rounds
     | .base_ref = $base_ref
     | .base_sha = $base_sha
     | .provider = $provider
     | .status = "running"
     | .updated_at = $now' \
    "${STATE_DIR}/state.json" >"${STATE_DIR}/state.json.tmp"
```

**Step 2: Verify no tabs remain in the block**

```bash
grep -Pn '^\t' .agent/scripts/prepare-round.sh
```
Expected: no output.

**Step 3: Run test**

```bash
bash .agent/scripts/test-prepare-round.sh
```
Expected: `Prepare round tests passed`

---

## Task 6: Fix F4 — AGENT_BENCHMARK_* vars set to empty string in local path

**Files:**
- Modify: `agent-cycle:71-74`

When `benchmark.sh` exists locally, `download_dir` stays `""`, so `${download_dir:+...}` expands to `""`. The env vars are then set to empty string instead of remaining unset, which can mislead `benchmark.sh`.

**Step 1: Conditionally set the env vars**

Change lines 71–75 from:
```bash
  AGENT_BENCHMARK_CASES_FILE="${AGENT_BENCHMARK_CASES_FILE:-${download_dir:+${download_dir}/benchmarks/cases.yml}}" \
    AGENT_BENCHMARK_PROVIDERS_FILE="${AGENT_BENCHMARK_PROVIDERS_FILE:-${download_dir:+${download_dir}/benchmarks/providers.yml}}" \
    AGENT_BENCHMARK_RUBRIC_FILE="${AGENT_BENCHMARK_RUBRIC_FILE:-${download_dir:+${download_dir}/benchmarks/rubric.yml}}" \
    GH_BIN="${GH_BIN:-$gh_bin}" \
    bash "$benchmark_script" "$@"
```
to:
```bash
  if [[ -n "$download_dir" ]]; then
    AGENT_BENCHMARK_CASES_FILE="${AGENT_BENCHMARK_CASES_FILE:-${download_dir}/benchmarks/cases.yml}" \
      AGENT_BENCHMARK_PROVIDERS_FILE="${AGENT_BENCHMARK_PROVIDERS_FILE:-${download_dir}/benchmarks/providers.yml}" \
      AGENT_BENCHMARK_RUBRIC_FILE="${AGENT_BENCHMARK_RUBRIC_FILE:-${download_dir}/benchmarks/rubric.yml}" \
      GH_BIN="${GH_BIN:-$gh_bin}" \
      bash "$benchmark_script" "$@"
  else
    GH_BIN="${GH_BIN:-$gh_bin}" \
      bash "$benchmark_script" "$@"
  fi
```

**Step 2: Verify syntax**

```bash
bash -n agent-cycle
```
Expected: no output (syntax OK).

---

## Task 7: Fix F6 — EXIT trap overwrite in benchmark()

**Files:**
- Modify: `agent-cycle:54-56` (the `else` branch where `download_dir` is assigned)

`trap 'rm -rf "$download_dir"' EXIT` overwrites any prior EXIT trap. Use a pattern that chains instead.

**Step 1: Save prior trap before setting a new one, restore it after**

In the `else` branch of `benchmark()`, replace:
```bash
    download_dir="$(mktemp -d)"
    trap 'rm -rf "$download_dir"' EXIT
```
with:
```bash
    download_dir="$(mktemp -d)"
    _prior_trap="$(trap -p EXIT)"
    trap 'rm -rf "$download_dir"' EXIT
```

And in the cleanup block (lines 76–79), replace:
```bash
  if [[ -n "$download_dir" ]]; then
    rm -rf "$download_dir"
    trap - EXIT
  fi
```
with:
```bash
  if [[ -n "$download_dir" ]]; then
    rm -rf "$download_dir"
    if [[ -n "$_prior_trap" ]]; then
      eval "$_prior_trap"
    else
      trap - EXIT
    fi
  fi
```

Also declare `_prior_trap` at the top of the function:
```bash
  local _prior_trap=""
```

**Step 2: Verify syntax**

```bash
bash -n agent-cycle
```
Expected: no output.

---

## Task 8: Commit untracked benchmark files (Fix F2)

The 8 files listed in `validate-engine.sh`'s `required_files` array that are untracked must be committed so the engine self-validates on a fresh clone.

**Step 1: Stage all untracked benchmark/test files**

```bash
git add \
  .agent/scripts/benchmark.sh \
  .agent/scripts/test-benchmark.sh \
  .agent/scripts/test-prepare-round.sh \
  .agent/scripts/test-finalize-round.sh \
  benchmarks/cases.yml \
  benchmarks/providers.yml \
  benchmarks/rubric.yml \
  docs/benchmarking.md
```

**Step 2: Verify they are now tracked**

```bash
git status --short
```
Expected: all 8 files show `A` (staged, new file), not `??`.

**Step 3: Verify validate-engine.sh passes (required_files check)**

```bash
bash -c 'for f in .agent/scripts/benchmark.sh .agent/scripts/test-benchmark.sh .agent/scripts/test-prepare-round.sh .agent/scripts/test-finalize-round.sh benchmarks/cases.yml benchmarks/providers.yml benchmarks/rubric.yml docs/benchmarking.md; do [[ -s "$f" ]] || { echo "MISSING: $f"; exit 1; }; done && echo "All required files present"'
```
Expected: `All required files present`

---

## Task 9: Full validation run

Run the complete engine validation to confirm all fixes together:

```bash
bash .agent/scripts/test-prepare-round.sh && \
bash .agent/scripts/test-finalize-round.sh && \
bash -n agent-cycle && \
echo "All targeted tests pass"
```

Expected output:
```
Prepare round tests passed
Finalize round tests passed
All targeted tests pass
```

Note: `bash .agent/scripts/validate-engine.sh` requires `ruby` and all scripts to be present. Run it if the full environment is available; otherwise the three targeted tests above are sufficient to confirm the code-level fixes.

---

## Commit Strategy

After all tasks complete and tests pass:

```bash
git add \
  .agent/scripts/finalize-round.sh \
  .agent/scripts/prepare-round.sh \
  .agent/scripts/test-finalize-round.sh \
  agent-cycle \
  .agent/scripts/benchmark.sh \
  .agent/scripts/test-benchmark.sh \
  .agent/scripts/test-prepare-round.sh \
  benchmarks/cases.yml \
  benchmarks/providers.yml \
  benchmarks/rubric.yml \
  docs/benchmarking.md

git commit -m "fix: address benchmark feature code review findings

- finalize-round: guard drift check with non-empty SHA to prevent API-failure false positives (F1)
- finalize-round: move git push inside commit guard in publish_state_changes path (F3)
- prepare-round: resolve FETCH_HEAD to SHA immediately after fetch (F7)
- prepare-round: add error message on git fetch SHA failure (F5)
- prepare-round: fix mixed tabs/spaces in jq block (F8)
- agent-cycle: avoid setting AGENT_BENCHMARK_* to empty string in local path (F4)
- agent-cycle: save/restore prior EXIT trap in benchmark() (F6)
- commit 8 untracked benchmark files required by validate-engine.sh (F2)"
```
