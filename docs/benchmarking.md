# Agent Benchmarking

This benchmark layer compares model providers through the existing Agent Cycle
workflow. It does not run agents locally. It creates one issue per
case/provider pair in a controlled target repository, triggers
`.github/workflows/agent-cycle.yml`, then collects the committed
`.agent_state/issues/<number>/` artifacts and PR metadata.

## Configuration

- `benchmarks/cases.yml`: open-source benchmark tasks. Every case must pin a
  source repository, a full 40-character commit SHA, and `target_ref`.
  `target_ref` must be a branch in the target repository, not a raw commit SHA
  or tag. For controlled forks, add `target_repository`; `run` dispatches
  `agent-cycle.yml` against that exact target branch and passes the resolved
  branch SHA as the task-branch base commit.
- `benchmarks/providers.yml`: provider IDs and the workflow provider value sent
  to `agent-cycle.yml`.
- `benchmarks/rubric.yml`: score weights and finding penalties.

Use controlled forks or mirrors of the listed open-source repositories. Do not
create benchmark issues or PRs directly in upstream projects. If a case omits
`target_repository`, `--target-repo` must match `source_repository`; otherwise
the command fails instead of running the task against the wrong repository.
`target_ref` must exist as a branch and contain `source_commit`; the runner
verifies that before issue creation, dispatch, and collection.

## Workflow

Validate the benchmark definition:

```bash
agent-cycle benchmark validate-config
```

Create benchmark issues in the target repository:

```bash
agent-cycle benchmark create-issues --target-repo OWNER/REPO
```

Benchmark issues are created with the `agent-benchmark` label. The shipped
listener skips normal issue events for that label, so issue creation does not
start a default-provider run.

Trigger the provider matrix:

```bash
agent-cycle benchmark run --target-repo OWNER/REPO
```

For each case, `run` dispatches the workflow with the case's `target_ref` as
both the workflow ref and PR `base_ref`, plus the resolved `base_sha`. The
reusable engine creates the first `agent/issue-<number>` task branch from that
base SHA; later rounds continue from the existing task branch.

Collect compact JSONL results:

```bash
agent-cycle benchmark collect --target-repo OWNER/REPO --out benchmark-results.jsonl
```

Render the provider report:

```bash
agent-cycle benchmark report --input benchmark-results.jsonl --out benchmark-report.md
```

Use `--dry-run` with `create-issues` or `run` to inspect planned GitHub
operations before creating issues or starting workflows.
