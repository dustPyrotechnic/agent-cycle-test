# Templates Module Memory

These files are copied into target repositories; they are not executed from the
central engine.

- Root `install.sh` is the target-repository bootstrapper. It renders this
  module's listener template for a selected engine repository/ref, configures
  target repository settings through `gh`, and delegates missing secret input
  directly to `gh secret set` without reading secret values itself. Remote
  execution tries anonymous raw template download first, then authenticated
  `gh api` so private engines remain installable.
- `agent-cycle-listener.yml`: the target repository's listener. It reacts to
  `solve-it` labels, `agent-relay` dispatches, and manual runs, then calls the
  central `reusable-agent-cycle.yml`. It must declare `contents`, `issues`, and
  `pull-requests` write permissions and pass model secrets explicitly; reusable
  workflows do not inherit caller secrets without an explicit `secrets:` block.
- Production listeners must pin the engine to a release tag or commit SHA. `@main`
  is for engine development only, because central `main` changes reach every
  target at once. They must pass `engine_repository` as well as `engine_ref` so
  a custom or forked engine checks out the same repository whose reusable
  workflow was invoked.
- The listener should expose `provider` and `max_rounds` `workflow_dispatch`
  inputs and forward `vars.AGENT_TRUSTED_ASSOCIATIONS`, otherwise maintainers
  cannot manually pick a provider or round limit and configured trusted
  associations are silently ignored.

Post-round validation (`validate-target.sh`) runs in the privileged finalize
context, so it performs only static checks and never executes target-controlled
code. Project-specific validation is the agent's responsibility during the round,
where Claude Code runs without a GitHub token or privileged Actions credentials.
