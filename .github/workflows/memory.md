# Workflow Module Memory

## Agent Cycle

`agent-cycle.yml` runs only for:

- A `solve-it` label event.
- A validated `agent-relay` repository dispatch.
- A manual dispatch for an existing `solve-it` issue.

The workflow copies `.agent` to runner temporary storage before the model runs. All privileged preparation and finalization use this snapshot.

`GITHUB_TOKEN` is sufficient for branch pushes, pull requests, issue updates, and `repository_dispatch`. Do not introduce `MY_AGENT_PAT` without a requirement that the scoped token cannot satisfy.

Model credentials are injected only into the Claude Code step. That step starts Claude Code with a clean environment so runner-internal tokens and workflow command paths are not inherited.

The repository setting `Actions -> General -> Allow GitHub Actions to create and approve pull requests` must be enabled. Workflow-level `pull-requests: write` is not sufficient when that setting is disabled.

## Validation

`validate.yml` runs the repository-owned validator on pushes and pull requests.
