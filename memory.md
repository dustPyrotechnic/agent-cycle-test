# Repository Memory

## Purpose

The repository implements a safe-by-default, issue-driven coding loop on GitHub Actions. A maintainer opts an issue in with the `solve-it` label. Each run performs one bounded Claude Code round, persists state on `agent/issue-<number>`, and either completes, blocks, or relays through `repository_dispatch`.

## Durable Decisions

- The deterministic shell wrapper owns GitHub mutations. The model edits files and reports status only.
- Every issue gets an isolated branch and concurrency group.
- A hard round limit prevents unbounded cost and recursion.
- Only issues authored by `OWNER` are accepted by default. `AGENT_TRUSTED_ASSOCIATIONS` can explicitly broaden that list.
- Changes always exit through a pull request; the agent never pushes to the default branch.
- Provider credentials are read only from Actions secrets.
- `MY_AGENT_PAT` is intentionally unused. The scoped `GITHUB_TOKEN` can create `repository_dispatch` events.

## State Contract

Per-issue state lives under `.agent_state/issues/<number>/` on the task branch:

- `issue.md`: latest issue snapshot.
- `state.json`: wrapper-owned round counter and lifecycle state.
- `handoff.md`: agent-owned concise context for the next round.
- `result.json`: agent-owned structured result for the current round.
