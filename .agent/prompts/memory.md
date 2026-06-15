# Prompt Module Memory

`agent-round.md` is the common trusted pipeline contract. Role-specific system
prompts define analyst, implementer, verifier, and reviewer responsibilities,
permissions, and output contracts. `run-round.sh` appends the common prompt,
role prompt, and only that role's relevant skills to Claude Code's system prompt.

`agent-round.md` mandates Chinese for every natural-language string the agents
emit, regardless of issue language; role prompts must not reintroduce a
follow-the-issue-language rule. The wrapper-authored issue comments, PR body, and
runtime summaries in `run-round.sh` / `finalize-round.sh` are likewise Chinese,
so every reply posted to an issue is fully Chinese.

The agents run in separate sessions. Their explicit handoff artifacts are:

- Analyst -> `analysis.json`
- Implementer -> `implementation.json`
- Verifier -> `verification.json`
- Reviewer -> `review.json`, copied to `result.json`

Keep the reviewer result schema compatible with `.agent/scripts/finalize-round.sh`. Status values are:

- `continue`: useful work landed, but another bounded round is required.
- `complete`: requested work is implemented and adequately verified.
- `blocked`: progress requires a maintainer decision or unavailable external dependency.
