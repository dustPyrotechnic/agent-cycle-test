# Shell Orchestration Memory

## Script Responsibilities

- `prepare-round.sh`: validates the trusted issue, checks out the task branch, increments persisted state, and marks the issue running.
- `run-round.sh`: configures the selected provider and invokes four independent
  specialized Claude Code sessions in order: analyst, implementer, verifier,
  reviewer. It validates and persists each handoff artifact before starting the
  next role.
- `finalize-round.sh`: validates the result, commits and pushes changes, updates the PR and issue, and optionally dispatches the next round.

### Agent output parsing (`run-round.sh`)

- Each phase output is passed through `normalize_agent_json` before its `jq`
  contract check. Models may wrap the required JSON in a Markdown code fence or
  add conversational preamble despite the prompt; the helper recovers the JSON
  object in place (fenced block first, then widest brace span) and leaves
  genuinely malformed output untouched so it still fails the contract loudly.
- The analyst contract accepts a third status, `satisfied`, for when the
  requested outcome already holds and no increment is needed. The wrapper
  finalizes a `satisfied` analysis directly as a terminal `complete` result
  (recording the analyst's `validation_plan` as tests and `evidence` as
  findings) and skips the implementer, verifier, and reviewer. `satisfied`
  requires a non-empty `validation_plan`; `ready` still requires a non-empty
  `implementation_plan` and `validation_plan`.
- `validate-engine.sh`: validates the central engine repository (shell/YAML syntax, synchronized root instructions, required module memory, reusable workflow, listener template). Runs in CI; blocks engine releases.
- `validate-target.sh`: validates the target repository after a round. Its
  current generic static check parses workflow YAML. It runs in the privileged
  finalize context, so it must never execute target-controlled code or impose
  engine-specific root-instruction parity. Never requires the engine memory
  layout.
- `validate.sh`: backward-compatible shim that execs `validate-engine.sh`.
- `test-specialized-pipeline.sh`: uses fake Claude and timeout executables in
  isolated repositories to verify sequential handoff, the verifier completion
  gate, read-only mutation detection, protected-state enforcement, credential
  leak publication blocking, fenced/preamble-wrapped output recovery, and the
  analyst `satisfied` terminal short-circuit, without network or real model
  credentials.
- `test-installer.sh`: installs listeners into isolated repositories and verifies
  default rendering, custom engine/provider/private-engine rendering, YAML
  syntax, the `agent-cycle` local/installed shortcut paths, authenticated
  download fallback for private engines, and refusal to overwrite an existing
  listener without `--force`.

## Engine and Target Roots

- `ENGINE_ROOT` (default `WRAPPER_ROOT`, then `.agent`): the trusted snapshot the scripts and prompt are read from. The credential-leak sentinel lives here, out of the target tree.
- `TARGET_ROOT` (default git toplevel): the target repository working tree. Every git, gh, and dispatch operation runs here. Each script `cd`s to `TARGET_ROOT` before touching the working tree.

## Security Boundaries

- Workflow scripts are copied to runner temporary storage before Claude Code runs. Finalization executes that snapshot, so normal working-tree edits do not alter the active privileged wrapper.
- `GH_TOKEN` is scoped only to trusted configure/prepare/finalize workflow steps;
  it is not present in the model step. Claude Code starts with a temporary clean
  home and a clean environment containing only the model provider variables and
  basic process variables. It receives no GitHub token, PAT, Actions runtime
  token, or workflow file-command path.
- The wrapper suspends GitHub Actions workflow-command parsing while each
  untrusted agent response is streamed to logs, then restores parsing with an
  unpredictable per-phase token.
- Claude Code runs with `--bare`; target-controlled hooks, plugins, MCP servers,
  auto-memory, and discovered skills are disabled. Trusted role prompts and
  skills are appended explicitly from `ENGINE_ROOT`.
- Analyst, verifier, and reviewer receive only Bash/Read/Glob/Grep tools. The
  wrapper fingerprints the Git working tree before and after each read-only
  phase; any mutation creates an out-of-tree sentinel that prevents publication.
  Only the implementer receives edit authority.
- The wrapper fingerprints `.agent_state/issues` before and after the
  implementer phase. Implementer changes to wrapper-owned lifecycle state or
  prior handoff artifacts create an out-of-tree sentinel and prevent
  publication; `.agent_state/memory.md` remains normal repository documentation.
- The model step scans tracked and untracked files for the configured provider credential. A match creates an out-of-tree sentinel that stops publication.
- Never interpolate issue title or body into shell code.
