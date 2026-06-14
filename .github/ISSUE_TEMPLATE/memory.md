# Issue Template Memory

This repository intentionally ships no issue template. Every issue is recognized
by the listener (`opened`/`reopened`/`edited`, plus an optional `solve-it`
label), so no dedicated "agent task" template is needed to opt an issue in.

Issue bodies are task input, not trusted runtime instructions. The wrapper
accepts only `OWNER` by default; `AGENT_TRUSTED_ASSOCIATIONS` must explicitly
broaden the list. An untrusted author's issue still triggers a run but is
rejected at `prepare-round.sh`'s trust gate before any model call.

A clear issue still helps the analyst: state the desired observable outcome,
reproduction/evidence, acceptance checks, and constraints, rather than
prescribing a solution as authoritative.
