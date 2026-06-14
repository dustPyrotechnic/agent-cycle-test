# Agent Cycle Test

[![Validate Agent Configuration](https://github.com/dustPyrotechnic/agent-cycle-test/actions/workflows/validate.yml/badge.svg)](https://github.com/dustPyrotechnic/agent-cycle-test/actions/workflows/validate.yml)

这是一个由 GitHub Issue 驱动的有界自循环编码代理，并且是一个**中央可复用引擎**：每个目标仓库只需安装一个小型监听器并配置模型密钥，即可让代理识别该仓库的**所有** Issue。新建（或重新打开、编辑）任意 Issue 即触发，无需专门的标签或模板；真正放行哪些 Issue 由信任门控（`author_association`，默认仅 `OWNER`）决定。目标仓库的监听器调用中央 `reusable-agent-cycle.yml`，代理在目标仓库的独立分支完成一个可审查增量，包装脚本持久化状态、创建 Pull Request，并在需要时通过 `repository_dispatch` 接力下一轮。

可复用工作流运行在**调用仓库**的 `github` 上下文和 `GITHUB_TOKEN` 下，因此所有 Issue、分支、PR 和接力操作都作用于目标仓库，而非引擎仓库。中央仓库自己的 `agent-cycle.yml` 通过本地 `./` 引用调用同一个可复用引擎，与目标仓库走完全相同的生产路径。

## 安全模型

- 默认只接受仓库 `OWNER` 创建的 Issue，可通过 `AGENT_TRUSTED_ASSOCIATIONS` 显式扩大范围。
- 每个 Issue 使用独立的 `agent/issue-<number>` 分支与并发锁。
- 默认最多运行 5 轮；每轮依次运行分析、实现、验证和审查四个独立 Agent。
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

1. 创建 Issue，明确期望结果与验收检查。新建 Issue 即自动触发，无需任何标签或模板。
2. 在 Actions 中观察 `Agent Cycle`。
3. 在生成的 Pull Request 中审查实现和每轮状态。
4. 合并 Pull Request 后，`Closes #<issue>` 会关闭 Issue。

如需对已有 Issue 人工重跑，可重新打开/编辑该 Issue、给它打上 `solve-it` 标签，或从 Actions 手动运行工作流并选择 Issue 编号、提供商和轮数上限。

## 接入目标仓库

当前中央引擎是私有仓库。发布稳定的 `v1` tag 后，在任意目标仓库目录运行以下一条认证命令，即可完成监听器安装、GitHub 仓库设置、`solve-it` 标签、可信作者变量和模型 Secret 检查，并只提交、推送监听器文件：

```bash
bash <(gh api --method GET -H 'Accept: application/vnd.github.raw+json' repos/dustPyrotechnic/agent-cycle-test/contents/install.sh -f ref=v1) --private-engine --commit
```

安装器要求本机已有 `git`、已认证的 `gh` 和目标仓库的管理员权限。缺少 `DEEPSEEK_API_KEY` 或私有引擎所需的 `ENGINE_TOKEN` 时，它会调用 `gh secret set` 安全读取并加密 Secret，安装脚本本身不会读取或打印 Secret 内容。当前分支不是默认分支时，需要先合并该分支，监听器才会生效。

引擎开发期间还没有稳定 tag 时，可以显式使用 `main`：

```bash
bash <(gh api --method GET -H 'Accept: application/vnd.github.raw+json' repos/dustPyrotechnic/agent-cycle-test/contents/install.sh -f ref=main) --engine-ref main --private-engine --commit
```

如果未来将中央引擎设为公开仓库，也可以改用匿名
`bash <(curl -fsSL https://raw.githubusercontent.com/.../install.sh)` 形式。

常用安装选项：

```bash
# 仅生成监听器，不修改 GitHub 设置，也不提交
bash /path/to/agent-cycle-test/install.sh --engine-ref main --local-only

# 使用 MiMo，并允许 OWNER 和 MEMBER 创建任务
bash /path/to/agent-cycle-test/install.sh --provider mimo --trusted-associations OWNER,MEMBER --commit

# 中央引擎为私有仓库时，同时配置 ENGINE_TOKEN 映射
bash /path/to/agent-cycle-test/install.sh --private-engine --commit
```

私有中央引擎还必须在自身 Actions 设置中允许目标仓库调用 reusable workflow；`ENGINE_TOKEN` 需要是能够读取中央引擎的跨仓库 PAT 或 GitHub App token。

不使用安装器时，仍可手动复制 `templates/agent-cycle-listener.yml` 到目标仓库的 `.github/workflows/agent-cycle.yml`，并完成相同的仓库设置。生产监听器必须固定到稳定 tag 或 commit SHA；`uses:`、`engine_repository` 与 `engine_ref` 必须指向同一个引擎版本来源。

每轮结束后的 `validate-target.sh` 运行在持有 Token 的特权 finalize 上下文中，因此**只做静态检查**（当前为工作流 YAML 解析），绝不执行目标仓库可控的代码。项目专属验证由代理在轮次内完成——那时 Claude Code 不接收 GitHub Token、PAT 或 Actions 运行时凭据。

## 自循环协议

每一轮不是一个 Agent 自行分析并批准自己的修改，而是中央包装脚本固定编排：

```text
Analyst -> analysis.json
    -> Implementer -> implementation.json + code changes
    -> Verifier -> verification.json
    -> Reviewer -> review.json/result.json
```

- Analyst 使用任务分析和系统化调试 skill，只读检查问题并形成实施计划。
- Implementer 使用测试驱动变更 skill，是唯一允许编辑目标仓库的角色。
- Verifier 使用独立回归验证 skill，只运行验证并记录证据，不修复代码。
- Reviewer 使用证据驱动审查 skill，读取真实 diff 和前三阶段产物；只有 Verifier 为 `pass` 时才能报告 `complete`。

四个 Agent 使用相互独立的 Claude Code 会话。中央可信 prompt 和 skill 通过 system prompt 注入；目标仓库中的 hooks、plugins、MCP、自动发现 skills 会被 `--bare` 禁用。前一 Agent 的已校验输出文件路径会显式传给后一 Agent。

Analyst、Verifier 和 Reviewer 只能使用 `Bash/Read/Glob/Grep`。包装脚本会比较每个只读阶段前后的 Git 工作树内容指纹；如果只读角色产生可提交改动，本轮将停止且不会发布任何 Agent 修改。Implementer 可以修改目标代码，但包装脚本会单独保护 wrapper 管理的 `.agent_state/issues`，阻止它篡改生命周期状态和前序交接物。

### 专门化方法论来源

中央 skills 和角色提示词是针对本引擎重新编写的紧凑版本，主要借鉴以下 GitHub 项目的设计：

- [`obra/superpowers`](https://github.com/obra/superpowers)（MIT）：[`systematic-debugging`](https://github.com/obra/superpowers/blob/main/skills/systematic-debugging/SKILL.md)、[`test-driven-development`](https://github.com/obra/superpowers/blob/main/skills/test-driven-development/SKILL.md)、[`verification-before-completion`](https://github.com/obra/superpowers/blob/main/skills/verification-before-completion/SKILL.md)、[`subagent-driven-development`](https://github.com/obra/superpowers/blob/main/skills/subagent-driven-development/SKILL.md)。
- [`SWE-agent/SWE-agent`](https://github.com/SWE-agent/SWE-agent)（MIT）：Issue 驱动的仓库修改，以及 [`config/default.yaml`](https://github.com/SWE-agent/SWE-agent/blob/main/config/default.yaml) 中“先复现、修复后重新验证”的流程。
- [`OpenAutoCoder/Agentless`](https://github.com/OpenAutoCoder/Agentless)（MIT）：故障定位、修复、独立补丁验证分阶段执行。
- [`microsoft/agent-framework`](https://github.com/microsoft/agent-framework)（MIT）：显式顺序工作流和阶段 handoff。
- [`github/awesome-copilot`](https://github.com/github/awesome-copilot)（MIT）：专业 Debug、Implementation、QA 和 Review Agent 的角色划分。

没有直接复制第三方完整提示词；中央提示词保留了本项目自己的权限边界、状态协议和 GitHub wrapper 责任划分。

每轮状态持久化在任务分支的 `.agent_state/issues/<number>/`：

| 文件 | 所有者 | 作用 |
| --- | --- | --- |
| `issue.md` | 包装脚本 | 最新 Issue 快照 |
| `state.json` | 包装脚本 | 轮数、提供商与生命周期 |
| `handoff.md` | 包装脚本 | 从最终审查派生的下一轮紧凑上下文 |
| `result.json` | Reviewer / 包装脚本 | 已校验的 `continue`、`complete` 或 `blocked` 结果 |
| `analysis.json` | Analyst | 问题证据、根因或变更理由、实施与验证计划 |
| `implementation.json` | Implementer | 实际改动、测试结果和计划偏差 |
| `verification.json` | Verifier | 独立测试与验收证据 |
| `review.json` | Reviewer | 最终审查结论和具体 findings |

`continue` 会触发下一轮；`complete` 会停止接力并等待 PR 审查；`blocked` 会停止并等待维护者处理。

## 本地验证

```bash
# 校验中央引擎自身完整性（CI 同样运行此脚本；validate.sh 是其兼容别名）
bash .agent/scripts/validate-engine.sh

# 校验某个目标仓库工作树（仅静态安全检查，不执行目标代码）
TARGET_ROOT=/path/to/target bash .agent/scripts/validate-target.sh
```

本地运行完整代理轮次还需要 GitHub 上下文和对应提供商 API Key，通常应通过 Actions 验证。

## 文档入口

- 根级执行规则：`CLAUDE.md`、`AGENTS.md`
- 架构决策：`memory.md`
- Agent 运行时：`.agent/memory.md`
- GitHub 编排：`.github/memory.md`
- 目标仓库监听器模板：`templates/memory.md`
- 持久化状态：`.agent_state/memory.md`
- 跨仓库改造计划：`CROSS_REPO_MIGRATION_PLAN.md`
- 跨仓库测试与验收：`CROSS_REPO_TEST_PLAN.md`
