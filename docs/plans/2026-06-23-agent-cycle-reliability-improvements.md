# Agent Cycle Reliability Improvements Plan

**Goal:** 分阶段提升本仓库作为中央 Agent Cycle 引擎的可靠性、可恢复性和可验证性，并尽量使用本项目运行自身 Issue 的方式完成 dogfood 验收。

**Scope:** 本计划覆盖四类提升：

1. Agent JSON 输出鲁棒性。
2. `prepare-round.sh` / `finalize-round.sh` GitHub wrapper 路径自动化测试。
3. `.agent_state` 保留策略与文档化。
4. 只读阶段隔离增强。

**Non-goals:**

- 不改变“wrapper 拥有 GitHub mutation，agent 只做代码与报告”的核心边界。
- 不引入默认自动合并 PR。
- 不把目标仓库特定测试放进 privileged `validate-target.sh` 执行。

---

## 背景

当前项目整体结构清晰，且已有以下保护：

- `run-round.sh` 顺序编排 analyst -> implementer -> verifier -> reviewer。
- 每个阶段有 JSON schema 校验。
- 只读阶段使用工作树指纹检测非法修改。
- Implementer 阶段保护 `.agent_state/issues`。
- 模型凭据写入工作树时会触发 out-of-tree sentinel，阻止发布。
- `validate-engine.sh` 已覆盖 shell/YAML 静态检查、specialized pipeline fake-agent 测试和 installer 测试。

现有缺口主要不是“当前红灯”，而是可靠性和覆盖面可以继续提高：

- 模型输出 JSON 中的裸双引号仍可能导致合法分析被丢弃。
- `prepare-round.sh` 与 `finalize-round.sh` 的 GitHub mutation 路径缺少 fake-`gh` 自动测试。
- `.agent_state/issues/<n>` 会进入 agent 分支和 PR；这可能是审计设计，也可能成为目标仓库主干污染，需要明确策略。
- 只读阶段指纹主要覆盖 Git 可见改动，对 ignored 文件、缓存和 `.git` 副作用的隔离不够硬。

---

## Dogfood Strategy: 用本项目修复自身

本仓库本身已经通过 `.github/workflows/agent-cycle.yml` dogfood 同一个 reusable engine。建议把每个阶段拆成一个小 Issue，让 Agent Cycle 修复自己的引擎，并用 wrapper 产生的 PR 作为可靠性样本。

### 基本规则

1. 每个 Issue 只覆盖一个阶段或一个明确子任务。
2. Issue 必须给出验收命令，优先使用本仓库已有验证：

```bash
bash .agent/scripts/validate-engine.sh
shellcheck agent-cycle install.sh .agent/scripts/*.sh
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/*.yml templates/*.yml
git diff --check
```

3. 观察每轮生成的 `.agent_state/issues/<issue-number>/`，确认四阶段 artifact 的状态转换合理。
4. 每个 dogfood PR 合并前人工检查：
   - 是否只改预期文件。
   - reviewer 是否基于 verifier 的 `pass` 才报告 `complete`。
   - Issue 评论、标签、PR body 是否与状态一致。
   - 没有凭据、runner token 或临时路径泄漏。

### 推荐 Issue 拆分

1. `fix: repair bare double quotes in agent JSON output`
   - 对应本计划 Phase 1。
   - 可以直接引用 `docs/plans/2026-06-21-fix-json-unescaped-quotes.md`。

2. `test: add fake-gh coverage for prepare and finalize wrappers`
   - 对应 Phase 2。
   - 要求新增本地测试，不依赖真实 GitHub API。

3. `docs: define agent state retention policy`
   - 对应 Phase 3。
   - 先做文档决策，不立即重构状态存储。

4. `test: detect ignored-file side effects from readonly agents`
   - 对应 Phase 4 的短期检测增强。
   - 如果该 Issue 暴露设计复杂度，再拆第二个 Issue 做隔离重构。

---

## Phase 1: Agent JSON 输出鲁棒性

**Objective:** 降低模型输出轻微 JSON 格式错误导致整轮 `blocked` 的概率。

**Primary plan:** `docs/plans/2026-06-21-fix-json-unescaped-quotes.md`

### Files

- Modify: `.agent/prompts/agent-round.md`
- Modify: `.agent/prompts/analyst-system.md`
- Modify: `.agent/scripts/run-round.sh`
- Modify: `.agent/scripts/test-specialized-pipeline.sh`
- Update if needed: `.agent/prompts/memory.md`
- Update if needed: `.agent/scripts/memory.md`

### Implementation Steps

1. Add a failing fake-agent scenario before changing the normalizer.
   - Scenario name: `fenced-quotes`.
   - Analyst output: Chinese prose preamble + fenced JSON block + bare double quotes inside string values.
   - Expected before fix: schema validation falls back to `blocked`.
   - Expected after fix: pipeline proceeds and completes.

2. Add prompt-level guardrails.
   - In `agent-round.md`, state that natural-language JSON string values must not contain bare `"` when quoting words or phrases.
   - In `analyst-system.md`, repeat the warning near the final response contract.

3. Add last-resort JSON repair.
   - Keep current `jq` parse path first.
   - Keep current invalid-backslash repair second.
   - Add a conservative Python stdlib repair path only after both fail.
   - The repair path must validate with `jq` before replacing the candidate.

4. Keep failure behavior explicit.
   - If all repair paths fail, leave output invalid and let the existing schema failure path write a blocked result.
   - Do not silently accept partial JSON or multiple objects.

### Validation

```bash
bash .agent/scripts/test-specialized-pipeline.sh
bash .agent/scripts/validate-engine.sh
shellcheck agent-cycle install.sh .agent/scripts/*.sh
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/*.yml templates/*.yml
git diff --check
```

### Dogfood Acceptance

- Agent Cycle should create a PR in this repository.
- The PR should contain the new test and implementation.
- `.agent_state/issues/<n>/verification.json` should include the full validation commands.
- Reviewer should only return `complete` when verifier reports `pass`.

---

## Phase 2: GitHub Wrapper Fake Tests

**Objective:** 把 `prepare-round.sh` 与 `finalize-round.sh` 的 GitHub mutation 路径纳入本地自动测试，减少跨仓库路径只能靠手工验收的问题。

### Files

- Add: `.agent/scripts/test-github-wrapper.sh`
- Modify: `.agent/scripts/validate-engine.sh`
- Update: `.agent/scripts/memory.md`

### Test Harness Design

Use isolated temporary repositories and fake executables:

- Fake `gh`
  - Records calls to a log file.
  - Returns deterministic JSON for:
    - `gh api repos/<repo>/issues/<number>`
    - `gh api repos/<repo>`
    - label creation
    - issue edit/comment
    - PR list/create
    - repository dispatch
  - Can be configured per scenario to fail specific operations.

- Real `git`
  - Use local bare remotes to verify branches, commits, and pushed refs.
  - Avoid network access.

- No real model
  - `run-round.sh` does not need to run in these tests.
  - Write minimal `result.json` and `state.json` fixtures directly when testing finalize.

### Scenarios

1. Trusted author prepares a new branch.
   - `prepare-round.sh` creates `.agent_state/issues/<n>/issue.md`.
   - State round increments from 0 to 1.
   - Branch `agent/issue-<n>` is pushed.
   - `agent-running` is added and stale terminal labels are removed.

2. Non-trusted author is rejected.
   - `prepare-round.sh` exits non-zero.
   - No branch is pushed.
   - No model-facing state is created.

3. Round limit blocks prepare.
   - Existing `state.json.round` equals `MAX_ROUNDS`.
   - `prepare-round.sh` exits non-zero before starting a new round.

4. `publish_changes:false` does not publish branch/PR.
   - Fixture result status is `blocked`.
   - `finalize-round.sh` comments and labels issue.
   - No `git push`.
   - No `gh pr create`.

5. `continue` dispatches next round.
   - Fixture result status is `continue`.
   - `finalize-round.sh` calls `repos/<repo>/dispatches`.
   - Payload includes issue number, provider, and max rounds.

6. PR creation failure is visible.
   - Fake `gh pr create` returns non-zero.
   - `finalize-round.sh` exits non-zero.
   - Test asserts the run does not silently claim success.

7. Sentinel paths stop publication.
   - `credential-leak-detected`
   - `readonly-phase-mutation-detected`
   - `protected-state-mutation-detected`
   - Each should comment, add `agent-blocked`, remove `agent-running`, and exit non-zero.

### Validation

```bash
bash .agent/scripts/test-github-wrapper.sh
bash .agent/scripts/validate-engine.sh
shellcheck agent-cycle install.sh .agent/scripts/*.sh
git diff --check
```

### Dogfood Acceptance

- The dogfood PR should add the new test script and wire it into `validate-engine.sh`.
- A later Agent Cycle run should execute the new test as part of central validation.
- Failure logs should be readable without exposing token values.

---

## Phase 3: `.agent_state` Retention Policy

**Objective:** 明确 `.agent_state/issues/<n>` 是否应该进入目标仓库主干，以及维护者如何清理或保留这些状态文件。

### Decision Options

#### Option A: Keep committed state in PRs

Pros:

- Recovery is simple across runners.
- Reviewers can audit every role artifact.
- No separate storage or API lookup is required.

Cons:

- Target repository main branch accumulates agent runtime state.
- Product code PRs include operational metadata.
- Long-term cleanup policy must be explicit.

#### Option B: Keep state only on agent branches

Pros:

- Target main branch stays clean.
- State remains available while PR is open.

Cons:

- Final merge needs to exclude `.agent_state`.
- More complicated finalize logic.
- Multi-round recovery must still find prior branch state.

#### Option C: Move state to a dedicated state branch or issue comments

Pros:

- Cleanest product branches.
- State lifecycle can be managed separately.

Cons:

- More GitHub mutation paths.
- More concurrency and recovery edge cases.
- Harder local inspection.

### Recommendation

Short term: choose Option A and document it as an intentional audit trail.

Reasoning:

- The existing architecture already depends on committed state for round recovery.
- Current tests and docs expect `.agent_state/issues/<n>` in PRs.
- A storage migration should happen only after Phase 2 expands wrapper tests.

### Files

- Modify: `README.md`
- Modify: `memory.md`
- Modify: `.agent_state/memory.md`
- Modify: `CROSS_REPO_TEST_PLAN.md`

### Documentation Changes

Add a short policy section explaining:

- `.agent_state/issues/<n>` is intentionally committed on agent task branches.
- If merged, it serves as compact audit and recovery metadata.
- It must never contain secrets, raw model transcripts, caches, or build artifacts.
- Maintainers may delete closed/completed issue state in a normal cleanup PR if they do not need the audit trail.
- Invalid/insufficient evidence rounds may still create state before `publish_changes:false` suppresses PR creation.

### Validation

```bash
grep -n "agent_state" README.md memory.md .agent_state/memory.md CROSS_REPO_TEST_PLAN.md
bash .agent/scripts/validate-engine.sh
git diff --check
```

### Dogfood Acceptance

- Use a documentation-only Issue.
- The generated PR should only modify policy docs plus `.agent_state/issues/<n>`.
- Reviewer should confirm no behavior change.

---

## Phase 4: Read-Only Phase Isolation

**Objective:** Reduce side effects from analyst, verifier, and reviewer phases beyond normal tracked-file mutation.

### Current Behavior

`run-round.sh` computes a working tree fingerprint before and after each read-only phase using:

- `git diff --binary --no-ext-diff HEAD`
- `git status --porcelain=v1 --untracked-files=all`
- hashes for untracked non-ignored files

This catches normal tracked/untracked mutations, but does not fully cover:

- Ignored files.
- Build caches.
- Tool state under ignored directories.
- `.git` mutations.
- Side effects outside the repository.

### Step 1: Add a Regression Test for Ignored Side Effects

Before changing isolation, add a test proving current behavior.

Scenario:

- Target repo has `.gitignore` ignoring `cache/`.
- Read-only fake analyst writes `cache/side-effect.txt`.
- Test records current behavior and desired behavior.

Preferred desired behavior:

- Either the wrapper detects the side effect and writes `readonly-phase-mutation-detected`, or the side effect is run in a disposable copy and cannot reach later phases.

### Step 2: Short-Term Detection Enhancement

Extend read-only phase fingerprinting to include ignored files under selected repository-local paths.

Possible strategy:

- Use `git status --porcelain=v1 --ignored=matching --untracked-files=all`.
- Hash ignored files only under the repository root.
- Exclude known huge directories only if necessary and document the exclusion.

Risk:

- Large ignored dependency folders such as `node_modules` could make fingerprinting slow.

Mitigation:

- Start with targeted ignored paths created during the run rather than hashing all ignored files.
- Measure runtime in `test-specialized-pipeline.sh`.

### Step 3: Medium-Term Disposable Read-Only Worktree

If detection becomes too expensive or incomplete, run read-only agents in a disposable copy:

1. Copy or checkout target repository into a temporary directory for analyst/verifier/reviewer.
2. Run read-only agent there.
3. Copy only its output JSON back to the real target root.
4. Delete the temporary directory.

Risks:

- Verifier and reviewer must inspect the implementer's actual diff. The disposable copy must include the current post-implementer working tree.
- Copying large repositories can be slow.
- Paths in reports must still match target repository paths.

### Files

- Modify: `.agent/scripts/run-round.sh`
- Modify: `.agent/scripts/test-specialized-pipeline.sh`
- Update: `.agent/scripts/memory.md`

### Validation

```bash
bash .agent/scripts/test-specialized-pipeline.sh
bash .agent/scripts/validate-engine.sh
shellcheck agent-cycle install.sh .agent/scripts/*.sh
git diff --check
```

### Dogfood Acceptance

- Start with the ignored-file regression test Issue.
- If the agent proposes a large isolation rewrite immediately, reviewer should prefer a smaller tested increment unless evidence shows detection is insufficient.

---

## Release Sequence

1. Complete Phase 1 and release a patch tag if JSON failures are currently observed in real runs.
2. Complete Phase 2 before any structural storage or isolation refactor.
3. Complete Phase 3 as docs once the state policy is decided.
4. Complete Phase 4 in at least two PRs:
   - test/detection increment
   - isolation or fingerprinting implementation

---

## Global Validation Checklist

Before tagging a release after these changes:

```bash
bash .agent/scripts/validate-engine.sh
shellcheck agent-cycle install.sh .agent/scripts/*.sh
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/*.yml templates/*.yml
git diff --check
cmp CLAUDE.md AGENTS.md
```

Manual checks:

- Run one dogfood Issue in this repository.
- Run one target-repository Issue through `templates/agent-cycle-listener.yml`.
- Confirm no central repository resource is created for target-repository work.
- Confirm no credential value appears in logs, PR diff, issue comments, or `.agent_state`.
- Confirm `agent-running` is removed on `complete` and `blocked`.

---

## Rollback Plan

- Prompt-only changes can be reverted independently.
- JSON repair changes can be disabled by reverting `normalize_json_candidate` while keeping tests for future work.
- New fake-`gh` tests can be temporarily removed from `validate-engine.sh` if they are flaky, but the script should remain in the tree until fixed.
- `.agent_state` documentation changes have no runtime effect.
- Read-only isolation changes should be released after wrapper tests exist; if they regress runtime, revert the isolation implementation and keep the regression test as blocked/expected-failure documentation only if necessary.
