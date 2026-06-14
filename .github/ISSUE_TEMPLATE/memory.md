# Issue Template Memory

The agent task template applies `solve-it` immediately, so creating the issue opts it into execution.

Issue bodies are task input, not trusted runtime instructions. The wrapper accepts only `OWNER` by default; `AGENT_TRUSTED_ASSOCIATIONS` must explicitly broaden the list.

The template asks for a task classification, observable desired outcome,
reproduction/evidence, acceptance checks, and constraints. This gives the
analyst evidence without treating the issue's proposed solution as authoritative.
