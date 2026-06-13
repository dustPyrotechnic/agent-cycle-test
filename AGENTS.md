# Repository Agent Instructions

This repository hosts a bounded, issue-driven GitHub agent cycle.

## Operating Rules

1. Read the target issue snapshot and the current handoff before editing.
2. Work on one bounded round. Prefer a small verified increment over broad unfinished changes.
3. Run the most relevant available validation before reporting completion.
4. Never print, persist, or inspect API keys and tokens.
5. Do not commit, push, create pull requests, comment on issues, or trigger another run. Wrapper scripts own those operations.
6. Finish every round by writing the required JSON result and a concise handoff.
7. Keep `CLAUDE.md` and `AGENTS.md` byte-for-byte identical when root instructions change.

## Progressive Disclosure

Load only the memory relevant to the files being changed:

| Scope | Read first |
| --- | --- |
| Repository architecture and durable decisions | `memory.md` |
| Agent runtime | `.agent/memory.md` |
| Shell orchestration | `.agent/scripts/memory.md` |
| Agent prompt contract | `.agent/prompts/memory.md` |
| GitHub configuration | `.github/memory.md` |
| Workflows | `.github/workflows/memory.md` |
| Issue templates | `.github/ISSUE_TEMPLATE/memory.md` |
| Persisted cycle state | `.agent_state/memory.md` |

When a module gains a durable convention or non-obvious constraint, update that module's `memory.md`. Do not use memory files as activity logs.
