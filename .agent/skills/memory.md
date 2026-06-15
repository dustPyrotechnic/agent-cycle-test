# Specialized Skills Memory

These are trusted, compact methodology prompts loaded explicitly from
`ENGINE_ROOT` for the specialized pipeline agents. They are not discovered from
the target repository or the temporary Claude home.

## Role Mapping

- Analyst: `task-analysis`, `systematic-debugging`, and `cyber-divination-debug`.
- Implementer: `test-driven-change`.
- Verifier: `regression-verification`.
- Reviewer: `evidence-based-review`.

## Research Basis

- `obra/superpowers` (MIT): systematic debugging, test-driven development,
  verification before completion, code review, and subagent-driven development.
- `SWE-agent/SWE-agent` (MIT): issue-driven repository work and
  reproduce-before-fix prompt patterns.
- `microsoft/agent-framework` (MIT): explicit sequential workflows and typed
  handoff artifacts.
- `OpenAutoCoder/Agentless` (MIT): fault localization, repair, and independent
  patch validation stages.
- `github/awesome-copilot` (MIT): specialized debug, implementation, QA, and
  review agent role definitions.

`cyber-divination-debug` is vendored from the external repository
`dustPyrotechnic/cyber-divination-debug`; it is an evidence-gate skill (request
missing diagnostic materials before guessing) loaded only for the analyst.

The other repository skills are original compact adaptations for this engine. Keep
them deterministic, role-specific, and small enough to append to the trusted
system prompt every round. Every role returns a Shell-validated JSON artifact;
do not rely on free-form conversation history for role handoff.
