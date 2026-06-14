# Cycle State Memory

This directory is committed on agent task branches so a new GitHub Actions runner can resume without relying on artifacts or caches.

Do not store secrets, raw model transcripts, build artifacts, or dependency
caches here. Store only compact pipeline artifacts:

- `issue.md` and `state.json` from the wrapper.
- `analysis.json` from the analyst.
- `implementation.json` from the implementer.
- `verification.json` from the verifier.
- `review.json` and `result.json` from the reviewer/wrapper.
- `handoff.md` derived from the final review for the next round.
