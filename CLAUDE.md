# Repository Agent Instructions

This repository hosts a bounded, issue-driven GitHub agent cycle. It is a central, reusable engine: target repositories install `templates/agent-cycle-listener.yml` and call `.github/workflows/reusable-agent-cycle.yml`. Trusted scripts and the prompt are read from `ENGINE_ROOT`; all git, gh, and dispatch operations run against the target repository at `TARGET_ROOT`.

## Operating Rules

1. Read the target issue snapshot and the current handoff before editing.
2. Work on one bounded round. Prefer a small verified increment over broad unfinished changes.
3. Run the most relevant available validation before reporting completion.
4. Never print, persist, or inspect API keys and tokens.
5. Do not commit, push, create pull requests, comment on issues, or trigger another run. Wrapper scripts own those operations.
6. Respect the assigned pipeline role and artifact contract. Only the reviewer decides final status; the wrapper derives `result.json` and `handoff.md`.
7. Keep `CLAUDE.md` and `AGENTS.md` byte-for-byte identical when root instructions change.

## Progressive Disclosure

Load only the memory relevant to the files being changed:

| Scope | Read first |
| --- | --- |
| Repository architecture and durable decisions | `memory.md` |
| Agent runtime | `.agent/memory.md` |
| Shell orchestration | `.agent/scripts/memory.md` |
| Agent prompt contract | `.agent/prompts/memory.md` |
| Specialized agent skills | `.agent/skills/memory.md` |
| GitHub configuration | `.github/memory.md` |
| Workflows | `.github/workflows/memory.md` |
| Issue templates | `.github/ISSUE_TEMPLATE/memory.md` |
| Target listener templates | `templates/memory.md` |
| Persisted cycle state | `.agent_state/memory.md` |

When a module gains a durable convention or non-obvious constraint, update that module's `memory.md`. Do not use memory files as activity logs.
