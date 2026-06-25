# Workflow Module Memory

## Reusable Agent Cycle

`reusable-agent-cycle.yml` is the central engine, invoked via `workflow_call`. It runs with the CALLING repository's `github` context and `GITHUB_TOKEN`, so it acts on the target repository, never the engine. It:

- Checks out the engine repository (`inputs.engine_repository`) at `inputs.engine_ref` to a sibling path, then snapshots the engine `.agent` to `ENGINE_ROOT`, and checks out the target repository to `TARGET_ROOT`.
- Runs prepare, run, and finalize from the engine snapshot against the target tree.
- Gives one bounded round enough time for four sequential specialized sessions:
  analyst, implementer, verifier, and reviewer. Each phase has its own timeout.
- Accepts optional `base_ref` and `base_sha`; `prepare-round.sh` uses `base_sha`
  only when first creating the per-issue agent branch, while `base_ref` remains
  the PR base branch. Benchmark runs therefore start from a resolved commit
  without losing the branch needed for review.

The engine ref problem: a reusable workflow has NO caller-independent way to learn its own ref. `github.workflow_ref` resolves to the caller's listener (the `github` context belongs to the caller), and `github.job_workflow_ref`/`job_workflow_sha` are not real `github` context properties. Therefore the caller passes `engine_repository` and `engine_ref`, keeping them in sync with the repository and `@ref` pinned in its `uses:` line. Empty `engine_ref` defaults to `$GITHUB_SHA`, which is correct only for the engine's own self-listener (local `./` call).

Two more constraints apply:

- The `runner` context (e.g. `runner.temp`) is unavailable in job-level `env:`. Export `ENGINE_ROOT`/`TARGET_ROOT` from a step using the `$RUNNER_TEMP`/`$GITHUB_WORKSPACE` shell variables into `$GITHUB_ENV`.
- Listeners must forward `vars.AGENT_TRUSTED_ASSOCIATIONS` and expose
  `provider`/`max_rounds`/`base_ref`/`base_sha` `workflow_dispatch` inputs, or those
  documented capabilities silently fall back to defaults.

## Agent Cycle (central self-listener)

`agent-cycle.yml` is the central repository's own listener. It calls `reusable-agent-cycle.yml` via a local `./` reference so the engine exercises the same production path as targets. It runs for:

- Any issue `opened`, `reopened`, or `edited` event unless the issue has the
  `agent-benchmark` label.
- A `labeled` event only when the label is `solve-it` (optional manual re-run).
- A validated `agent-relay` repository dispatch.
- A manual `workflow_dispatch` for an existing issue number.

Every non-benchmark issue is recognized; `prepare-round.sh`'s trust gate, not a
label, decides which ordinary issues actually run. Benchmark issues are skipped
on issue events and run only through explicit workflow dispatch.

The reusable engine copies `.agent` to runner temporary storage before the model runs. All privileged preparation and finalization use this snapshot.

`GITHUB_TOKEN` is sufficient for branch pushes, pull requests, issue updates, and `repository_dispatch`. Do not introduce `MY_AGENT_PAT` without a requirement that the scoped token cannot satisfy.

Model credentials are injected only into the Claude Code step. `GH_TOKEN` is
injected only into trusted configure/prepare/finalize steps and is absent from
the model step. Claude Code itself starts with a clean environment so
runner-internal tokens and workflow command paths are not inherited.

The repository setting `Actions -> General -> Allow GitHub Actions to create and approve pull requests` must be enabled. Workflow-level `pull-requests: write` is not sufficient when that setting is disabled.

## Validation

`validate.yml` runs `validate-engine.sh`, ShellCheck, and pinned Actionlint on
pushes and pull requests to guard central engine integrity. Target-repository
checks happen at finalize time via `validate-target.sh`.
