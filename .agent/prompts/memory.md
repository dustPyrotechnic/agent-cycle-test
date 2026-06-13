# Prompt Module Memory

The round prompt is deliberately procedural. It gives Claude Code the issue snapshot, handoff path, result schema, and authority boundaries.

Keep the result schema compatible with `.agent/scripts/finalize-round.sh`. Status values are:

- `continue`: useful work landed, but another bounded round is required.
- `complete`: requested work is implemented and adequately verified.
- `blocked`: progress requires a maintainer decision or unavailable external dependency.
