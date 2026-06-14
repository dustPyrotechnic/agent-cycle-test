# Agent Runtime Memory

## Boundaries

- `.agent/prompts/agent-round.md` defines the common trusted pipeline contract;
  role prompts specialize analyst, implementer, verifier, and reviewer sessions.
- `.agent/skills/` contains compact trusted methodologies explicitly appended to
  the relevant role's system prompt.
- `.agent/scripts/` performs trusted orchestration around the model.
- The runtime uses Claude Code through an Anthropic-compatible provider.
- DeepSeek is the default provider; MiMo is a supported manual or relay selection.

Each bounded round runs four independent Claude Code sessions in order:
analyst -> implementer -> verifier -> reviewer. The shell wrapper validates and
persists each phase artifact before passing its path to the next phase.

## Provider Configuration

- DeepSeek base URL: `https://api.deepseek.com/anthropic`
- DeepSeek model: `deepseek-v4-pro[1m]`
- MiMo base URL: `https://api.xiaomimimo.com/anthropic`
- MiMo model: `mimo-v2.5-pro`

Provider credentials must never be written to repository files or command output.
