# Agent Cycle Test

[![Validate Agent Configuration](https://github.com/dustPyrotechnic/agent-cycle-test/actions/workflows/validate.yml/badge.svg)](https://github.com/dustPyrotechnic/agent-cycle-test/actions/workflows/validate.yml)

这是一个由 GitHub Issue 驱动的有界自循环编码代理。维护者给 Issue 添加 `solve-it` 标签后，GitHub Actions 会启动一轮 Claude Code；代理在独立分支完成一个可审查增量，包装脚本持久化状态、创建 Pull Request，并在需要时通过 `repository_dispatch` 接力下一轮。

## 安全模型

- 只接受 `OWNER`、`MEMBER` 或 `COLLABORATOR` 创建的 Issue。
- 每个 Issue 使用独立的 `agent/issue-<number>` 分支与并发锁。
- 默认最多运行 5 轮，每轮模型执行最多 35 分钟。
- Claude Code 不接收 GitHub Token；提交、推送、Issue、PR 和接力操作由快照化包装脚本完成。
- 所有改动通过 Pull Request 交付，不直接写入默认分支。
- `CLAUDE.md` 与 `AGENTS.md` 同步维护，模块细节按需从各目录的 `memory.md` 加载。

## 凭据配置

进入仓库 `Settings -> Secrets and variables -> Actions -> Secrets`，配置至少一个模型提供商：

| 名称 | 用途 |
| --- | --- |
| `DEEPSEEK_API_KEY` | 默认提供商，使用 DeepSeek Anthropic 兼容接口 |
| `MIMO_API_KEY` | 可选提供商，使用 MiMo Anthropic 兼容接口 |

`Secrets and variables -> Agents` 是 Copilot cloud agent 的独立作用域，普通 Actions 工作流不能读取。若凭据最初配置在 Agents 中，需要复制到上述 Actions secrets；确认运行成功后，建议删除不再需要的明文 Agents variables。

`MY_AGENT_PAT` 不需要配置。工作流声明的 `GITHUB_TOKEN` 权限已经覆盖分支、Issue、Pull Request 与 `repository_dispatch`。

默认只接受仓库 `OWNER` 创建的 Issue。如确需允许组织成员或协作者，可创建非敏感 Actions variable `AGENT_TRUSTED_ASSOCIATIONS`，值为逗号分隔的 GitHub author association，例如 `OWNER,MEMBER`。

进入 `Settings -> Actions -> General -> Workflow permissions`，启用 **Allow GitHub Actions to create and approve pull requests**。即使工作流声明了 `pull-requests: write`，未启用该仓库设置时 GitHub 仍会拒绝自动创建 PR。

## 使用方法

1. 创建 Issue，明确期望结果与验收检查。
2. 添加 `solve-it` 标签，或使用 `Agent task` Issue 模板自动添加。
3. 在 Actions 中观察 `Agent Cycle`。
4. 在生成的 Pull Request 中审查实现和每轮状态。
5. 合并 Pull Request 后，`Closes #<issue>` 会关闭 Issue。

如需人工重跑，先确保 Issue 带有 `solve-it`，再从 Actions 手动运行工作流并选择 Issue 编号、提供商和轮数上限。

## 自循环协议

每轮状态持久化在任务分支的 `.agent_state/issues/<number>/`：

| 文件 | 所有者 | 作用 |
| --- | --- | --- |
| `issue.md` | 包装脚本 | 最新 Issue 快照 |
| `state.json` | 包装脚本 | 轮数、提供商与生命周期 |
| `handoff.md` | 代理 | 下一轮所需的紧凑上下文 |
| `result.json` | 代理 | `continue`、`complete` 或 `blocked` 结构化结果 |

`continue` 会触发下一轮；`complete` 会停止接力并等待 PR 审查；`blocked` 会停止并等待维护者处理。

## 本地验证

```bash
bash .agent/scripts/validate.sh
```

本地运行完整代理轮次还需要 GitHub 上下文和对应提供商 API Key，通常应通过 Actions 验证。

## 文档入口

- 根级执行规则：`CLAUDE.md`、`AGENTS.md`
- 架构决策：`memory.md`
- Agent 运行时：`.agent/memory.md`
- GitHub 编排：`.github/memory.md`
- 持久化状态：`.agent_state/memory.md`
