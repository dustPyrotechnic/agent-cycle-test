# Design: Trigger the agent cycle on all issues

Date: 2026-06-14
Status: Approved

## Problem

Starting the agent cycle requires a dedicated "Agent task" issue template (or a
manual `solve-it` label). Maintainers must consciously distinguish an "agent
issue" from a normal one. The goal is for the project to recognize all issues so
no special distinction is needed.

## Decisions

- **Trigger scope:** literally all issues trigger the workflow (`opened`,
  `reopened`, `edited`), plus the existing `labeled` (kept for an optional manual
  re-run), `workflow_dispatch`, and `repository_dispatch` (relay).
- **Trust gate:** unchanged. `prepare-round.sh` still rejects issues whose
  `author_association` is outside `TRUSTED_ASSOCIATIONS` (default `OWNER`). Per
  the maintainer's choice, no author filter is added at the trigger level, so an
  untrusted author's issue still spins a run that fails at the internal gate
  before any model call.
- **`solve-it` label:** no longer a requirement in `prepare-round.sh`; retained
  only as an optional manual re-run trigger. The installer still creates it.
- **Issue template:** `.github/ISSUE_TEMPLATE/agent-task.yml` is removed
  entirely. All issues are plain free-form.
- **Concurrency:** already provided by `reusable-agent-cycle.yml`
  (`group: agent-cycle-<repo>-<issue>`, `cancel-in-progress: false`), so
  `edited`/`reopened` re-triggers queue behind a running round rather than
  overlapping. No new concurrency control is needed.

## Approach A (chosen): action-based `if` condition in the listener

Listener `on:` and the job `if:` express the gating. Non-`labeled` issue actions
always proceed; `labeled` only proceeds for `solve-it`.

```yaml
on:
  issues:
    types: [opened, reopened, edited, labeled]
  repository_dispatch:
    types: [agent-relay]
  workflow_dispatch:
    # unchanged

if: >-
  github.event_name == 'repository_dispatch' ||
  github.event_name == 'workflow_dispatch' ||
  (github.event_name == 'issues' && github.event.action != 'labeled') ||
  (github.event_name == 'issues' && github.event.action == 'labeled' && github.event.label.name == 'solve-it')
```

Rejected alternatives: (B) a trigger-level `author_association` filter — the
maintainer explicitly wants all issues to trigger; (C) a separate auto-label
workflow — extra moving parts and still label-based, contrary to the goal.

## Change list

### Behavior
1. `.github/workflows/agent-cycle.yml` — engine self-listener: new `on.issues.types`
   and Approach A `if:`.
2. `templates/agent-cycle-listener.yml` — target template: same `on:`/`if:`;
   setup-checklist comments note `solve-it` is now optional.
3. `.agent/scripts/prepare-round.sh` — remove the `solve-it` requirement block;
   keep the trust gate, PR discrimination, and round limit.
4. `.github/ISSUE_TEMPLATE/agent-task.yml` — delete.
5. `.agent/scripts/validate-engine.sh` — its YAML check globs
   `.github/ISSUE_TEMPLATE/*.yml`; with no YAML left there the unexpanded glob
   makes Ruby parse a nonexistent path. Make the check tolerate an empty
   directory (subshell `nullglob`, or `find`).

### Docs / memory (no logic change)
6. Update trigger descriptions in `memory.md`, `.github/memory.md`,
   `.github/workflows/memory.md`, `.github/ISSUE_TEMPLATE/memory.md`,
   `templates/memory.md`, `README.md`, and `install.sh` help text. Keep
   `solve-it` label creation in the installer (optional re-run entry). Keep
   `CLAUDE.md`/`AGENTS.md` byte-for-byte identical if touched.

### Tests
7. `test-installer.sh` — assert the rendered listener carries the new
   `types: [opened, reopened, edited, labeled]` to guard against regression.

## Testing & acceptance

- `prepare-round.sh` is not exercised by the two existing suites (they drive
  `run-round.sh` directly), so the `solve-it` removal has no unit coverage;
  rely on YAML validation plus the end-to-end check below.
- Local: `shellcheck install.sh .agent/scripts/*.sh` and
  `bash .agent/scripts/validate.sh` pass.
- End-to-end: after merging to `main`, open a plain, unlabeled issue and confirm
  the Agent Cycle triggers and reaches `agent-done`.
