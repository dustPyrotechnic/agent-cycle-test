# Agent Runtime Memory

## Boundaries

- `.agent/prompts/agent-round.md` defines the model's round contract.
- `.agent/scripts/` performs trusted orchestration around the model.
- The runtime uses Claude Code through an Anthropic-compatible provider.
- DeepSeek is the default provider; MiMo is a supported manual or relay selection.

## Provider Configuration

- DeepSeek base URL: `https://api.deepseek.com/anthropic`
- DeepSeek model: `deepseek-v4-pro[1m]`
- MiMo base URL: `https://api.xiaomimimo.com/anthropic`
- MiMo model: `mimo-v2.5-pro`

Provider credentials must never be written to repository files or command output.
