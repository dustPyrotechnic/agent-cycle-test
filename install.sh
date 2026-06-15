#!/usr/bin/env bash
set -euo pipefail

ENGINE_REPOSITORY="${AGENT_ENGINE_REPOSITORY:-dustPyrotechnic/agent-cycle-test}"
ENGINE_REF="${AGENT_ENGINE_REF:-v1}"
TRUSTED_ASSOCIATIONS="${AGENT_TRUSTED_ASSOCIATIONS:-OWNER}"
PROVIDER="${AGENT_PROVIDER:-deepseek}"
WORKFLOW_PATH=".github/workflows/agent-cycle.yml"
PRIVATE_ENGINE=false
FORCE=false
LOCAL_ONLY=false
COMMIT_AND_PUSH=false
SKIP_SECRET_CHECK=false
PROGRESS_MODE="${AGENT_PROGRESS:-auto}"
PROGRESS_ENABLED=false
PROGRESS_TOTAL=0
PROGRESS_CURRENT=0
PROGRESS_BAR_WIDTH=24
PROGRESS_LABEL=""

usage() {
  cat <<'EOF'
Install the central Agent Cycle listener in the GitHub repository for the
current directory.

Usage:
  bash install.sh [options]

Options:
  --engine-repository OWNER/REPO  Central engine repository.
  --engine-ref REF                Stable engine tag or commit SHA (default: v1).
  --provider deepseek|mimo        Provider required during setup (default: deepseek).
  --trusted-associations LIST     GitHub author associations allowed to run tasks.
  --private-engine                Pass ENGINE_TOKEN to checkout a private engine.
  --commit                        Commit and push only the installed workflow file.
  --force                         Replace an existing listener workflow.
  --local-only                    Install the workflow without changing GitHub settings.
  --skip-secret-check             Do not check or prompt for required Actions secrets.
  --no-progress                   Disable the interactive progress bar.
  -h, --help                      Show this help.

The listener recognizes every issue; the optional solve-it label only re-runs an
existing one. The normal installer still creates that label, configures the
trusted-author variable, enables Actions and Actions-created pull requests, and
securely asks gh to set a missing provider secret. Secret values are never read
by this script.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '    %s\n' "$*"
}

setup_progress() {
  case "$PROGRESS_MODE" in
    auto)
      if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${CI:-}" ]]; then
        PROGRESS_ENABLED=true
      fi
      ;;
    always)
      PROGRESS_ENABLED=true
      ;;
    never) ;;
    *) fail "AGENT_PROGRESS must be auto, always, or never" ;;
  esac

  if [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]]; then
    if ((COLUMNS < 60)); then
      PROGRESS_BAR_WIDTH=12
    elif ((COLUMNS >= 100)); then
      PROGRESS_BAR_WIDTH=32
    fi
  fi
}

render_progress_bar() {
  local completed="$1"
  local filled=0
  local index=0
  local bar=""

  if ((PROGRESS_TOTAL > 0)); then
    filled=$((completed * PROGRESS_BAR_WIDTH / PROGRESS_TOTAL))
  fi
  while ((index < PROGRESS_BAR_WIDTH)); do
    if ((index < filled)); then
      bar="${bar}#"
    else
      bar="${bar}-"
    fi
    index=$((index + 1))
  done
  printf '[%s]' "$bar"
}

progress_start() {
  local label="$1"
  local next=$((PROGRESS_CURRENT + 1))

  PROGRESS_LABEL="$label"
  if [[ "$PROGRESS_ENABLED" == true ]]; then
    if ((PROGRESS_CURRENT > 0)); then
      printf '\n'
    fi
    printf '[%d/%d] %s\n' "$next" "$PROGRESS_TOTAL" "$label"
  else
    printf '==> [%d/%d] %s\n' "$next" "$PROGRESS_TOTAL" "$label"
  fi
}

progress_finish() {
  PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
  if [[ "$PROGRESS_ENABLED" == true ]]; then
    render_progress_bar "$PROGRESS_CURRENT"
    printf ' %d/%d %s\n' "$PROGRESS_CURRENT" "$PROGRESS_TOTAL" "$PROGRESS_LABEL"
  fi
}

run_step() {
  local label="$1"
  shift

  progress_start "$label"
  "$@"
  progress_finish
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

validate_inputs() {
  [[ "$ENGINE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    fail "invalid engine repository: $ENGINE_REPOSITORY"
  [[ "$ENGINE_REF" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    fail "invalid engine ref: $ENGINE_REF"
  [[ "$TRUSTED_ASSOCIATIONS" =~ ^[A-Z_]+(,[A-Z_]+)*$ ]] ||
    fail "trusted associations must be comma-separated uppercase GitHub associations"
  case "$PROVIDER" in
    deepseek | mimo) ;;
    *) fail "provider must be deepseek or mimo" ;;
  esac
}

required_secret_name() {
  case "$PROVIDER" in
    deepseek) printf 'DEEPSEEK_API_KEY\n' ;;
    mimo) printf 'MIMO_API_KEY\n' ;;
  esac
}

secret_exists() {
  local name="$1"
  gh secret list --repo "$TARGET_REPOSITORY" --app actions --json name \
    --jq ".[] | select(.name == \"${name}\") | .name" | grep -qx "$name"
}

ensure_secret() {
  local name="$1"
  if secret_exists "$name"; then
    note "Actions secret ${name} already exists"
    return
  fi

  if [[ ! -r /dev/tty ]]; then
    fail "Actions secret ${name} is missing; run: gh secret set ${name} --app actions --repo ${TARGET_REPOSITORY}"
  fi

  printf '\nActions secret %s is required. gh will read and encrypt it directly.\n' "$name" >/dev/tty
  gh secret set "$name" --app actions --repo "$TARGET_REPOSITORY" </dev/tty
}

render_listener() {
  local source="$1"
  local destination="$2"
  local private_engine="$3"

  awk \
    -v engine_repository="$ENGINE_REPOSITORY" \
    -v engine_ref="$ENGINE_REF" \
    -v provider="$PROVIDER" \
    -v private_engine="$private_engine" '
      /^[[:space:]]+uses: .*\/\.github\/workflows\/reusable-agent-cycle\.yml@/ {
        sub(/uses: .*/, "uses: " engine_repository "/.github/workflows/reusable-agent-cycle.yml@" engine_ref)
      }
      /^[[:space:]]+engine_ref: / {
        sub(/engine_ref: .*/, "engine_ref: " engine_ref)
      }
      /^[[:space:]]+engine_repository: / {
        sub(/engine_repository: .*/, "engine_repository: " engine_repository)
      }
      /^[[:space:]]+default: deepseek$/ {
        sub(/deepseek$/, provider)
      }
      /\|\| inputs\.provider \|\| '\''deepseek'\''/ {
        sub(/\|\| inputs\.provider \|\| '\''deepseek'\''/, "|| inputs.provider || '\''" provider "'\''")
      }
      private_engine == "true" && /^[[:space:]]+# engine_token:/ {
        sub(/# engine_token:/, "engine_token:")
      }
      { print }
    ' "$source" >"$destination"
}

download_listener_template() {
  local destination="$1"
  local raw_url="https://raw.githubusercontent.com/${ENGINE_REPOSITORY}/${ENGINE_REF}/templates/agent-cycle-listener.yml"

  if command -v curl >/dev/null 2>&1 &&
    curl -fsSL --retry 3 "$raw_url" -o "$destination" 2>/dev/null; then
    return
  fi

  if command -v gh >/dev/null 2>&1; then
    note "Anonymous download failed; retrying through authenticated gh api"
    gh api \
      --method GET \
      -H "Accept: application/vnd.github.raw+json" \
      "repos/${ENGINE_REPOSITORY}/contents/templates/agent-cycle-listener.yml" \
      -f "ref=${ENGINE_REF}" >"$destination" &&
      return
  fi

  fail "cannot download the listener template; authenticate gh for a private engine"
}

install_listener() (
  local script_dir=""
  local template=""
  local rendered=""
  local private_engine="false"

  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    if ! script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; then
      script_dir=""
    fi
  fi

  template="$(mktemp)"
  rendered="$(mktemp)"
  trap 'rm -f "$template" "$rendered"' EXIT

  if [[ -n "$script_dir" && -f "${script_dir}/templates/agent-cycle-listener.yml" ]]; then
    cp "${script_dir}/templates/agent-cycle-listener.yml" "$template"
  else
    note "Downloading listener template from ${ENGINE_REPOSITORY}@${ENGINE_REF}"
    download_listener_template "$template"
  fi

  if [[ "$PRIVATE_ENGINE" == true ]]; then
    private_engine="true"
  fi
  render_listener "$template" "$rendered" "$private_engine"

  grep -Fq "uses: ${ENGINE_REPOSITORY}/.github/workflows/reusable-agent-cycle.yml@${ENGINE_REF}" "$rendered" ||
    fail "rendered listener does not reference the requested engine"
  grep -Fq "engine_ref: ${ENGINE_REF}" "$rendered" ||
    fail "rendered listener does not pass the requested engine ref"
  grep -Fq "engine_repository: ${ENGINE_REPOSITORY}" "$rendered" ||
    fail "rendered listener does not pass the requested engine repository"

  if [[ -e "$WORKFLOW_PATH" ]] && ! cmp -s "$rendered" "$WORKFLOW_PATH" && [[ "$FORCE" != true ]]; then
    fail "${WORKFLOW_PATH} already exists and differs; rerun with --force to replace it"
  fi

  mkdir -p "$(dirname "$WORKFLOW_PATH")"
  cp "$rendered" "$WORKFLOW_PATH"

  if command -v ruby >/dev/null 2>&1; then
    ruby -e 'require "yaml"; YAML.parse_file(ARGV.fetch(0))' "$WORKFLOW_PATH"
  fi
  note "Installed ${WORKFLOW_PATH}"
)

verify_engine_ref() {
  local engine_is_private=""

  note "Checking engine ref ${ENGINE_REPOSITORY}@${ENGINE_REF}"
  engine_is_private="$(gh api "repos/${ENGINE_REPOSITORY}" --jq '.private')" ||
    fail "cannot inspect ${ENGINE_REPOSITORY}; verify repository access"
  if [[ "$TARGET_IS_PRIVATE" != true && "$engine_is_private" == true ]]; then
    fail "public target ${TARGET_REPOSITORY} cannot call reusable workflows from private engine ${ENGINE_REPOSITORY}; make the engine public, make the target private, or choose a public engine"
  fi
  if [[ "$engine_is_private" == true && "$PRIVATE_ENGINE" != true ]]; then
    fail "private engine ${ENGINE_REPOSITORY} requires --private-engine so its code can be checked out after the reusable workflow is resolved"
  fi
  gh api "repos/${ENGINE_REPOSITORY}/commits/${ENGINE_REF}" --silent ||
    fail "cannot access ${ENGINE_REPOSITORY}@${ENGINE_REF}; publish the ref or configure repository access"
}

inspect_target() {
  validate_inputs
  require_command git
  require_command awk

  TARGET_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    fail "run this installer inside the target git repository"
  cd "$TARGET_ROOT"

  if [[ "$LOCAL_ONLY" != true ]]; then
    require_command gh
    require_command jq
    gh auth status >/dev/null 2>&1 || fail "authenticate GitHub CLI first with: gh auth login"
    read -r TARGET_REPOSITORY TARGET_PERMISSION TARGET_IS_PRIVATE < <(
      gh repo view --json nameWithOwner,viewerPermission,isPrivate \
        --jq '.nameWithOwner + " " + .viewerPermission + " " + (.isPrivate | tostring)'
    )
    [[ "$TARGET_PERMISSION" == "ADMIN" ]] ||
      fail "admin permission is required to configure ${TARGET_REPOSITORY} (current: ${TARGET_PERMISSION})"
    note "Target repository: ${TARGET_REPOSITORY}"
    verify_engine_ref
  else
    note "Target directory: ${TARGET_ROOT}"
  fi
}

configure_github() {
  local actions_permissions=""
  local workflow_permissions=""
  local allowed_actions=""
  local default_workflow_permissions=""

  note "Enabling GitHub Actions while preserving the repository action policy"
  actions_permissions="$(gh api "repos/${TARGET_REPOSITORY}/actions/permissions")"
  if ! jq -e '.enabled == true' >/dev/null <<<"$actions_permissions"; then
    allowed_actions="$(jq -r '.allowed_actions // "all"' <<<"$actions_permissions")"
    gh api --method PUT "repos/${TARGET_REPOSITORY}/actions/permissions" \
      -F enabled=true \
      -f "allowed_actions=${allowed_actions}" \
      --silent
  fi

  note "Allowing GitHub Actions to create pull requests"
  workflow_permissions="$(gh api "repos/${TARGET_REPOSITORY}/actions/permissions/workflow")"
  default_workflow_permissions="$(jq -r '.default_workflow_permissions // "read"' <<<"$workflow_permissions")"
  gh api --method PUT "repos/${TARGET_REPOSITORY}/actions/permissions/workflow" \
    -f "default_workflow_permissions=${default_workflow_permissions}" \
    -F can_approve_pull_request_reviews=true \
    --silent

  note "Creating solve-it label and trusted-author variable"
  gh label create solve-it \
    --repo "$TARGET_REPOSITORY" \
    --color 5319e7 \
    --description "Run the bounded Agent Cycle for this issue" \
    --force
  gh variable set AGENT_TRUSTED_ASSOCIATIONS \
    --repo "$TARGET_REPOSITORY" \
    --body "$TRUSTED_ASSOCIATIONS"

  if [[ "$SKIP_SECRET_CHECK" != true ]]; then
    ensure_secret "$(required_secret_name)"
    if [[ "$PRIVATE_ENGINE" == true ]]; then
      ensure_secret ENGINE_TOKEN
      note "The private engine must also allow this repository to call its reusable workflow"
    fi
  fi
}

commit_listener() {
  local branch=""
  local default_branch=""

  if [[ -z "$(git status --porcelain -- "$WORKFLOW_PATH")" ]]; then
    note "Listener is unchanged; no commit needed"
    return
  fi

  branch="$(git branch --show-current)"
  [[ -n "$branch" ]] || fail "cannot commit from a detached HEAD"

  git add "$WORKFLOW_PATH"
  git commit --only "$WORKFLOW_PATH" -m "chore: install agent cycle listener"
  git push --set-upstream origin "$branch"

  if [[ "$LOCAL_ONLY" != true ]]; then
    default_branch="$(gh repo view "$TARGET_REPOSITORY" --json defaultBranchRef --jq '.defaultBranchRef.name')"
    if [[ "$branch" != "$default_branch" ]]; then
      note "Pushed ${branch}; merge it into ${default_branch} before opening issues for the agent"
    fi
  fi
}

while (($#)); do
  case "$1" in
    --engine-repository)
      (($# >= 2)) || fail "--engine-repository requires a value"
      ENGINE_REPOSITORY="$2"
      shift 2
      ;;
    --engine-ref)
      (($# >= 2)) || fail "--engine-ref requires a value"
      ENGINE_REF="$2"
      shift 2
      ;;
    --provider)
      (($# >= 2)) || fail "--provider requires a value"
      PROVIDER="$2"
      shift 2
      ;;
    --trusted-associations)
      (($# >= 2)) || fail "--trusted-associations requires a value"
      TRUSTED_ASSOCIATIONS="$2"
      shift 2
      ;;
    --private-engine)
      PRIVATE_ENGINE=true
      shift
      ;;
    --commit)
      COMMIT_AND_PUSH=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --local-only)
      LOCAL_ONLY=true
      shift
      ;;
    --skip-secret-check)
      SKIP_SECRET_CHECK=true
      shift
      ;;
    --no-progress)
      PROGRESS_MODE=never
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

PROGRESS_TOTAL=2
if [[ "$LOCAL_ONLY" != true ]]; then
  PROGRESS_TOTAL=$((PROGRESS_TOTAL + 1))
fi
if [[ "$COMMIT_AND_PUSH" == true ]]; then
  PROGRESS_TOTAL=$((PROGRESS_TOTAL + 1))
fi
setup_progress

cat <<EOF

Agent Cycle deployment

  Engine: ${ENGINE_REPOSITORY}@${ENGINE_REF}
  Provider: ${PROVIDER}
  Trusted associations: ${TRUSTED_ASSOCIATIONS}

EOF

run_step "Inspect target repository" inspect_target
run_step "Install listener workflow" install_listener

if [[ "$LOCAL_ONLY" != true ]]; then
  run_step "Configure GitHub repository" configure_github
fi

if [[ "$COMMIT_AND_PUSH" == true ]]; then
  run_step "Commit and push listener" commit_listener
fi

cat <<EOF

Deployment complete

  Engine: ${ENGINE_REPOSITORY}@${ENGINE_REF}
  Workflow: ${WORKFLOW_PATH}
  Trusted associations: ${TRUSTED_ASSOCIATIONS}

EOF

if [[ "$COMMIT_AND_PUSH" != true ]]; then
  printf 'Commit and push %s before opening issues for the agent.\n' "$WORKFLOW_PATH"
fi
