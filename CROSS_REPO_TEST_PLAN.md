# 跨仓库 Agent Cycle 测试与验收文档

## 1. 测试目标

验证中央 reusable workflow 能够安全、稳定地处理其他仓库的 Issue，并确保所有代码修改、状态、分支、PR、评论和接力事件都发生在目标仓库，而不是中央引擎仓库。

## 2. 测试范围

覆盖：

- 中央仓库回归。
- 目标仓库单轮任务。
- 目标仓库多轮接力。
- 权限、Secrets、可信作者和轮数限制。
- 中央引擎与目标代码隔离。
- 失败恢复和版本回滚。

不覆盖：

- GitHub App 全仓库自动安装。
- 非 GitHub Actions runner。
- 自动合并 PR。
- 无人工审核的默认分支写入。

## 3. 测试环境

### 3.1 仓库

| 角色 | 建议名称 | 用途 |
| --- | --- | --- |
| 中央引擎 | `dustPyrotechnic/agent-cycle-test` | 保存 reusable workflow 和 `.agent` 引擎 |
| 目标测试仓库 | `dustPyrotechnic/agent-cycle-target-test` | 验证跨仓库调用和修改 |

目标测试仓库应使用最小项目，例如：

```text
README.md
src/example.txt
.github/workflows/agent-cycle.yml
```

### 3.2 目标仓库配置

测试前确认：

- Actions 已启用。
- `Allow GitHub Actions to create and approve pull requests` 已启用。
- 已创建 `solve-it`、`agent-running`、`agent-done`、`agent-blocked` 标签。
- 已配置 `DEEPSEEK_API_KEY` Actions secret。
- 可选配置 `MIMO_API_KEY` Actions secret。
- 已安装目标仓库监听器。
- 监听器调用中央 reusable workflow 的测试版本。

### 3.3 中央仓库配置

- reusable workflow 可以被目标测试仓库访问。
- 中央引擎分支无未提交变更。
- 中央引擎自己的验证工作流通过。
- 测试阶段引用固定测试 commit SHA，避免执行中途变化。

## 4. 通用观测项

每次测试都记录：

- Issue URL。
- Agent Cycle run URL 和 run attempt。
- 目标仓库任务分支名。
- PR URL。
- `state.json` 的 `round`、`max_rounds`、`status` 和 `last_run_url`。
- Issue 最终标签。
- 中央仓库是否产生意外分支、PR、Issue 评论或 `.agent_state`。
- 目标仓库是否出现中央引擎不应复制的文件。

## 5. 自动静态验证

在中央仓库执行：

```bash
bash .agent/scripts/validate-engine.sh
shellcheck install.sh .agent/scripts/*.sh
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/*.yml templates/*.yml
git diff --check
cmp CLAUDE.md AGENTS.md
```

如果改造阶段尚未拆分 validator，则临时执行：

```bash
bash .agent/scripts/validate.sh
go run github.com/rhysd/actionlint/cmd/actionlint@latest .github/workflows/*.yml
git diff --check
cmp CLAUDE.md AGENTS.md
```

通过标准：

- 所有命令退出码为 0。
- reusable workflow 的 `workflow_call` 输入和 Secrets 定义完整。
- listener 模板包含 Issue、dispatch 和 manual 三类入口。

## 6. P0 核心验收测试

### TC-P0-01：中央仓库回归

目的：确认抽取 reusable workflow 后，中央仓库原有能力未退化。

步骤：

1. 在中央仓库创建验证 Issue。
2. 添加 `solve-it`。
3. 等待 Agent Cycle 完成。

预期：

- reusable workflow 被调用。
- 创建 `agent/issue-<number>` 分支。
- 创建中央仓库 PR。
- Issue 最终带 `agent-done`，不再带 `solve-it` 和 `agent-running`。
- 无直接写入默认分支。

### TC-P0-02：目标仓库单轮完成

目的：验证其他仓库可以通过小型监听器调用中央引擎。

Issue 内容建议：

```markdown
## 目标

在 README.md 末尾添加一行：Cross-repository agent verified.

## 验收

- README.md 包含指定文本。
- 本任务一轮内完成。
```

步骤：

1. 在目标测试仓库创建 Issue。
2. 添加 `solve-it`。
3. 等待工作流完成。

预期：

- Actions run 位于目标仓库。
- 分支 `agent/issue-<number>` 位于目标仓库。
- PR 位于目标仓库并只修改预期文件和 `.agent_state/issues/<number>/`。
- Issue 位于目标仓库并最终带 `agent-done`。
- 中央仓库没有新任务分支、PR、Issue 评论或状态文件。

### TC-P0-03：目标仓库多轮接力

目的：验证 `repository_dispatch` 回到目标仓库并继续调用中央引擎。

准备：

- 使用测试专用提示或任务，让第一轮明确写入 `status: continue`，第二轮完成。
- `max_rounds` 设置为至少 3。

步骤：

1. 在目标仓库创建多步骤 Issue。
2. 添加 `solve-it`。
3. 观察第一轮结束后的 dispatch。
4. 等待第二轮完成。

预期：

- 第一轮 `state.json.round == 1` 且结果为 `continue`。
- 第二个 Actions run 由目标仓库的 `repository_dispatch` 触发。
- 第二轮继续使用同一目标分支。
- 最终 `state.json.round == 2` 且状态为 `complete`。
- 只创建一个目标仓库 PR。
- 中央仓库没有接力 run 或任务状态。

### TC-P0-04：模型 Secret 隔离

目的：确认模型 Secret 只在模型步骤中可用，且不会写入仓库。

步骤：

1. 运行一个正常任务。
2. 检查 workflow 日志、目标分支差异和 `.agent_state`。
3. 搜索仓库中是否出现凭据值或明显凭据前缀。

预期：

- 日志不显示 Secret 明文。
- 目标分支不包含 Secret。
- finalize 步骤不注入模型 Secret。
- Claude Code 环境不包含 `GITHUB_TOKEN`、Actions runtime token 或 workflow command path。

### TC-P0-05：目标仓库权限正确

目的：确认所有写操作使用目标仓库 `GITHUB_TOKEN`。

步骤：

1. 完成目标仓库单轮任务。
2. 检查分支、PR、评论和标签。

预期：

- 所有资源均位于目标仓库。
- Git 提交由 `github-actions[bot]` 创建。
- PR 目标为目标仓库默认分支。
- 中央仓库无对应资源。

### TC-P0-06：生产版本固定

目的：确认目标仓库不会自动跟随中央 `main` 的未发布变化。

步骤：

1. 将目标监听器固定到 `@v1` 或 commit SHA。
2. 向中央 `main` 提交一个不影响该固定版本的测试变化。
3. 在目标仓库运行 Agent Cycle。

预期：

- run 使用固定版本。
- 中央 `main` 的新变化不影响目标 run。

## 7. P1 失败路径测试

### TC-P1-01：缺失 DeepSeek Secret

步骤：

1. 从目标测试仓库临时删除 `DEEPSEEK_API_KEY`。
2. 创建并触发 Issue。

预期：

- 模型步骤明确失败或进入 `blocked`。
- 不创建未经验证的代码 PR。
- Issue 留下可操作的失败信息。
- 不发生接力循环。

恢复：

1. 恢复 Secret。
2. 重新添加 `solve-it` 或手动运行。

### TC-P1-02：禁止 Actions 创建 PR

步骤：

1. 临时关闭目标仓库的 `Allow GitHub Actions to create and approve pull requests`。
2. 运行一个可完成任务。

预期：

- 分支可能成功推送。
- PR 创建明确失败。
- run 不应误报完整成功。
- 文档能指导恢复。

恢复：

1. 重新启用设置。
2. 重跑失败 job 或手动触发。
3. PR 创建成功。

### TC-P1-03：非可信作者

步骤：

1. 使用不在 `AGENT_TRUSTED_ASSOCIATIONS` 中的账号创建 Issue。
2. 添加 `solve-it`。

预期：

- prepare 阶段拒绝执行。
- 不创建任务分支。
- 不调用模型。
- 不创建 PR。

### TC-P1-04：轮数上限

步骤：

1. 创建始终要求继续的测试任务。
2. 设置 `max_rounds: 2`。

预期：

- 最多运行两轮。
- 第二轮后状态变为 `blocked`。
- 移除 `solve-it` 和 `agent-running`。
- 添加 `agent-blocked`。
- 不再产生第三个 dispatch。

### TC-P1-05：Agent 报告 blocked

步骤：

1. 创建需要未提供外部决策的 Issue。
2. 要求代理在缺少决策时报告 blocked。

预期：

- 最终标签为 `agent-blocked`。
- 不再接力。
- Issue 评论包含阻塞原因和下一步。

### TC-P1-06：中央 reusable workflow 不可访问

步骤：

1. 临时将监听器引用改为不存在的 tag，或撤销目标仓库访问权。
2. 触发 Issue。

预期：

- 调用工作流无法启动并给出明确的 reusable workflow 访问错误。
- 目标仓库没有代码或状态变更。
- 恢复引用后可以重新运行。

### TC-P1-07：目标仓库不存在中央 memory 结构

步骤：

1. 使用只有 README 的目标仓库。
2. 触发最小修改任务。

预期：

- 不因为缺少中央仓库专属 `.agent/*/memory.md` 而失败。
- 中央引擎验证与目标项目验证正确分离。
- 不自动把中央 memory 文件复制到目标仓库。

## 8. P2 并发与兼容测试

### TC-P2-01：同一 Issue 重复触发

步骤：

1. 快速重复添加 `solve-it` 或手动触发同一 Issue。

预期：

- 同一 Issue 的 concurrency group 串行执行。
- 不产生互相覆盖的分支提交。
- 轮数单调递增。

### TC-P2-02：不同 Issue 并行

步骤：

1. 在同一目标仓库同时触发两个 Issue。

预期：

- 使用不同分支和不同 concurrency group。
- 两个任务互不覆盖状态。

### TC-P2-03：非 main 默认分支

步骤：

1. 将目标测试仓库默认分支设为 `develop`。
2. 触发任务。

预期：

- 分支从 `develop` 创建。
- PR base 为 `develop`。

### TC-P2-04：MiMo 提供商

前提：目标仓库配置 `MIMO_API_KEY`。

步骤：

1. 手动触发并选择 `mimo`。

预期：

- 使用 MiMo Anthropic 兼容端点。
- 不需要 DeepSeek Secret。
- 其余分支、状态和 PR 行为一致。

## 9. 验收检查命令

以下命令中的仓库名和编号按实际测试替换。

检查目标 Issue：

```bash
gh issue view <issue-number> \
  --repo dustPyrotechnic/agent-cycle-target-test \
  --json state,labels,comments,url
```

检查目标 PR：

```bash
gh pr list \
  --repo dustPyrotechnic/agent-cycle-target-test \
  --state all \
  --json number,title,state,url,headRefName,baseRefName
```

检查目标 run：

```bash
gh run list \
  --repo dustPyrotechnic/agent-cycle-target-test \
  --limit 20 \
  --json name,event,status,conclusion,url,headBranch
```

确认中央仓库没有意外任务资源：

```bash
gh pr list \
  --repo dustPyrotechnic/agent-cycle-test \
  --state open \
  --json number,title,headRefName,url

git ls-remote \
  https://github.com/dustPyrotechnic/agent-cycle-test.git \
  'refs/heads/agent/issue-*'
```

检查目标分支状态文件：

```bash
git fetch origin agent/issue-<issue-number>
git show origin/agent/issue-<issue-number>:.agent_state/issues/<issue-number>/state.json
git diff --stat origin/<default-branch>...origin/agent/issue-<issue-number>
```

## 10. 测试记录模板

每个测试用例使用以下格式记录：

```markdown
### <测试编号和名称>

- 日期：
- 中央引擎版本：
- 目标仓库：
- Issue：
- Run：
- PR：
- 结果：通过 / 失败 / 阻塞
- 实际行为：
- 与预期差异：
- 后续操作：
```

## 11. 发布门槛

发布 `v1` 前必须满足：

- 所有 P0 测试通过。
- P1 测试全部执行，已知限制有明确文档和恢复路径。
- 中央仓库回归与目标仓库跨仓库测试均通过。
- 未发现 Secret、GitHub Token 或 runner 临时凭据泄漏。
- 没有任何测试将目标仓库任务资源写入中央仓库。
- 生产监听器固定到 release tag 或 commit SHA。
- 至少完成一次从旧版本回滚到上一稳定版本的演练。
