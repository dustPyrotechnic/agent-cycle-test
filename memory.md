# Repository Memory

## Purpose

The repository is a central, reusable engine for a safe-by-default, issue-driven coding loop on GitHub Actions. The listener recognizes every issue (opened/reopened/edited, plus an optional `solve-it` label for manual re-runs); the trust gate in `prepare-round.sh` (`author_association` in `TRUSTED_ASSOCIATIONS`, default `OWNER`) decides which issues actually run. Each run performs one bounded four-session agent round, persists state on `agent/issue-<number>` in the target repository, and either completes, blocks, or relays through `repository_dispatch`.

## Architecture

- `.github/workflows/reusable-agent-cycle.yml` is the central engine, invoked via `workflow_call`. Target repositories install `templates/agent-cycle-listener.yml` and call it.
- Root `install.sh` bootstraps a target repository from its working directory: it installs the listener, configures the required GitHub settings, and can commit and push only the listener file.
- Root `agent-cycle` is a standalone convenience command. `agent-cycle setup`
  copies it to a local bin directory; `agent-cycle deploy` downloads or invokes
  `install.sh` and keeps that installer as the single source of deployment
  behavior.
- A reusable workflow runs with the CALLING repository's `github` context and `GITHUB_TOKEN`, so all issue, branch, PR, and dispatch operations act on the target repository, not the engine.
- The runner performs two checkouts: the target repository at `TARGET_ROOT` (default workspace context) and the central engine at a sibling path. The engine `.agent` is snapshotted to `ENGINE_ROOT` out of the target tree before the model runs.
- Each round uses a deterministic sequential pipeline: analyst -> implementer ->
  verifier -> reviewer. The previous role's validated artifact is passed by path
  to the next role, and only the reviewer can declare the round complete.
- The central repository's own `agent-cycle.yml` is a thin listener that calls the reusable engine via a local `./` reference, so the engine dogfoods the same production path.

## Durable Decisions

- The deterministic shell wrapper owns GitHub mutations. The model edits files and reports status only.
- The deterministic shell wrapper also owns role ordering, phase permissions,
  artifact validation, and final state transitions. Agents never choose their
  successor or trust an unvalidated prior-agent artifact.
- Trusted scripts and the prompt are read from `ENGINE_ROOT`; all git, gh, and dispatch operations run against `TARGET_ROOT`. Never address the engine repository as the target.
- Production listeners pin the engine to a release tag or commit SHA. The engine repository must be reachable from each target (public, or same organization with workflow access).
- Every issue gets an isolated branch and concurrency group.
- A hard round limit prevents unbounded cost and recursion.
- Only issues authored by `OWNER` are accepted by default. `AGENT_TRUSTED_ASSOCIATIONS` can explicitly broaden that list.
- Changes always exit through a pull request; the agent never pushes to the default branch.
- Provider credentials are read only from Actions secrets.
- `MY_AGENT_PAT` is intentionally unused. The scoped `GITHUB_TOKEN` can create `repository_dispatch` events.

## Validation

- `validate-engine.sh` checks the central engine's own integrity (shell/YAML syntax, synchronized root instructions, required memory, reusable workflow, and listener template). It runs in CI and must block engine releases. `validate.sh` is a backward-compatible shim to it.
- `validate-target.sh` runs after each round against `TARGET_ROOT`. It runs in the privileged finalize context, so it performs only static checks and never executes target-controlled code; project-specific validation is the agent's job during the round, where Claude Code receives no GitHub token, PAT, or Actions runtime credentials. An arbitrary target without the engine's memory layout is never failed for missing engine structure.

## State Contract

Per-issue state lives under `.agent_state/issues/<number>/` on the task branch:

- `issue.md`: latest issue snapshot.
- `state.json`: wrapper-owned round counter and lifecycle state.
- `handoff.md`: wrapper-derived concise context for the next round.
- `result.json`: validated reviewer decision or wrapper-generated runtime result.
- `analysis.json`: validated analyst implementation brief.
- `implementation.json`: validated implementer change and validation report.
- `verification.json`: independent verifier evidence.
- `review.json`: independent reviewer decision; copied to `result.json`.
