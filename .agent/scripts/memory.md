# Shell Orchestration Memory

## Script Responsibilities

- `prepare-round.sh`: validates the trusted issue, checks out the task branch, increments persisted state, and marks the issue running.
- `run-round.sh`: configures the selected provider and invokes one bounded Claude Code round.
- `finalize-round.sh`: validates the result, commits and pushes changes, updates the PR and issue, and optionally dispatches the next round.
- `validate.sh`: checks shell syntax, YAML syntax, synchronized root instructions, and required module memory.

## Security Boundaries

- Workflow scripts are copied to runner temporary storage before Claude Code runs. Finalization executes that snapshot, so normal working-tree edits do not alter the active privileged wrapper.
- Claude Code starts with a temporary clean home and a clean environment containing only the model provider variables and basic process variables. It receives no GitHub token, PAT, Actions runtime token, or workflow file-command path.
- The model step scans tracked and untracked files for the configured provider credential. A match creates an out-of-tree sentinel that stops publication.
- Never interpolate issue title or body into shell code.
