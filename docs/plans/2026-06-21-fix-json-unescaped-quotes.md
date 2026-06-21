# Fix: JSON Unescaped Quotes in Analyst Output Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复当分析师在 JSON 字符串值中写入裸双引号时，`normalize_agent_json` 无法修复、导致合法 `ready` 分析被契约校验丢弃的问题。

**Architecture:** 两层防御——提示词层约束消灭问题来源，Python 迭代修复层在提示词失效时兜底。两者均不引入外部依赖：提示词改动只涉及 Markdown 文件，Python3 在 GitHub Actions 标准 runner 上普遍可用。

**Tech Stack:** Bash (`run-round.sh`)，Python 3（标准库 `json` 模块），Markdown（提示词文件）

---

## 背景

**根因（两个缺陷叠加）：**

1. **`normalize_json_candidate` 的 awk 修复器只修复无效反斜杠转义（`\x`），完全不处理字符串值内的裸 `"`。** 当模型输出如 `"summary": "...英文 \"No code change\" 了..."` 这类带裸引号的字符串时，awk 修复器对此无能为力，`jq` 始终失败。

2. **`normalize_agent_json` 的围栏提取（Pass 2）成功后，若 `normalize_json_candidate` 失败，函数在第 107 行无条件 `return 0`，文件未被修改。** 后续契约校验运行在含散文前言的原始文件上，jq 必然失败，导致合法分析被丢弃，回退为通用 blocked 消息。

**触发场景（高频）：** 分析师在 JSON 字段中引用英文字符串字面量时，如：
- `"summary": "...行为与 \"No code change was required\" 不符..."` ← 裸引号
- `"root_cause_or_rationale": "第 492 行 printf 写死了 \"Next step:\"..."` ← 裸引号
- `"evidence": ["命令返回 \"not found\""]` ← 裸引号

---

## Task 1: 提示词层防御——禁止 JSON 字符串内使用裸双引号

**Files:**
- Modify: `.agent/prompts/agent-round.md`（Reply Language 节）
- Modify: `.agent/prompts/analyst-system.md`（Final Response 节）

### Step 1: 在 `agent-round.md` 的 Reply Language 节追加禁止裸引号规则

在 `.agent/prompts/agent-round.md` 第 25 行（`Keep JSON keys, status enums...` 行）之后，追加以下一句：

```
Never use bare double-quote characters (`"`) inside JSON string values to quote
a word or phrase; escape them as `\"` or rephrase using 「」instead. Bare quotes
inside strings produce invalid JSON that the pipeline cannot repair.
```

完整修改后的 Reply Language 节应为：

```markdown
## Reply Language

Write every natural-language string you emit in Chinese, regardless of the
language of the issue, repository, or prior artifacts. This applies to all prose
inside your JSON fields (summaries, evidence, rationale, plans, findings, risks,
concerns, and any status explanation). Keep JSON keys, status enums, code,
commands, file paths, identifiers, and URLs unchanged.

Never use bare double-quote characters (`"`) inside JSON string values to quote
a word or phrase; escape them as `\"` or rephrase using 「」instead. Bare quotes
inside strings produce invalid JSON that the pipeline cannot repair.
```

### Step 2: 在 `analyst-system.md` 的 Final Response 节追加同样的警告

在 `.agent/prompts/analyst-system.md` 第 36 行（`Return only one valid JSON object...` 行）之后，追加（紧跟在段落末尾，换行后）：

```
When quoting a string literal inside a field value, escape inner double quotes
as `\"` or use 「」rather than bare `"` characters; bare quotes break JSON
parsing and cannot be automatically repaired.
```

### Step 3: 验证 Markdown 文件不含语法错误

```bash
# 确认两个文件均可被 cat 正常读取、无乱码
cat .agent/prompts/agent-round.md
cat .agent/prompts/analyst-system.md
```

Expected: 正常输出，无报错。

### Step 4: Commit

```bash
git add .agent/prompts/agent-round.md .agent/prompts/analyst-system.md
git commit -m "fix: forbid bare double-quotes in JSON string values (prompt layer)"
```

---

## Task 2: Python 迭代修复——`normalize_json_candidate` 第三层兜底

**Files:**
- Modify: `.agent/scripts/run-round.sh`（`normalize_json_candidate` 函数，第 110–152 行）

### Step 1: 理解当前结构

`normalize_json_candidate` 当前逻辑（第 110–152 行）：
1. `[[ -s "$candidate" ]] || return 1`  — 空文件直接失败
2. `jq -e . "$candidate"` 成功 → `cp` 并 `return 0`
3. awk 修复无效反斜杠转义 → 写入 `$repaired`
4. `jq -e . "$repaired"` 成功/失败作为函数返回值

需要在第 4 步之后，若 jq 仍失败，加入 Python 迭代修复。

### Step 2: 在 `normalize_json_candidate` 中追加 Python 修复块

在第 151 行（`jq -e . "$repaired" >/dev/null 2>&1`）处，**将函数末尾的最后一个语句替换为**：

```bash
  if jq -e . "$repaired" >/dev/null 2>&1; then
    return 0
  fi

  # Last-resort: use Python to iteratively escape bare double-quotes that
  # appear inside JSON string values. json.JSONDecodeError.pos pinpoints the
  # exact offset of each offending character; inserting a backslash there and
  # retrying converges quickly for the common case where a model quoted an
  # English phrase using raw " characters inside a string value.
  if python3 - <"$repaired" >"${repaired}.py" 2>/dev/null <<'PYEOF'
import json, sys
text = sys.stdin.read()
try:
    json.loads(text)
    sys.stdout.write(text)
    sys.exit(0)
except json.JSONDecodeError:
    pass
chars = list(text)
for _ in range(200):
    t = ''.join(chars)
    try:
        json.loads(t)
        sys.stdout.write(t)
        sys.exit(0)
    except json.JSONDecodeError as e:
        if e.pos < len(chars) and chars[e.pos] == '"':
            chars.insert(e.pos, '\\')
        else:
            break
sys.exit(1)
PYEOF
  then
    mv "${repaired}.py" "$repaired"
    return 0
  fi

  rm -f "${repaired}.py"
  return 1
```

**注意**：函数最后一行原来是 `jq -e . "$repaired" >/dev/null 2>&1`，整个函数以该 jq 命令的退出码作为返回值。修改后，只有 Python 修复也失败时，才显式 `return 1`，逻辑更清晰。

### Step 3: 验证脚本语法

```bash
bash -n .agent/scripts/run-round.sh
```

Expected: 无输出（语法正确）。

### Step 4: 手动单元验证（Python 修复逻辑）

```bash
# 测试：含裸引号的无效 JSON → Python 应修复为合法 JSON
python3 - <<'EOF'
import json, sys
text = '{"status":"ready","summary":"含裸引号 "No code change" 的中文描述"}'
chars = list(text)
for _ in range(200):
    t = ''.join(chars)
    try:
        parsed = json.loads(t)
        print("修复成功:", parsed["summary"])
        sys.exit(0)
    except json.JSONDecodeError as e:
        if e.pos < len(chars) and chars[e.pos] == '"':
            chars.insert(e.pos, '\\')
        else:
            break
print("修复失败")
sys.exit(1)
EOF
```

Expected:
```
修复成功: 含裸引号 "No code change" 的中文描述
```

### Step 5: Commit

```bash
git add .agent/scripts/run-round.sh
git commit -m "fix: add Python iterative quote-escape repair to normalize_json_candidate"
```

---

## Task 3: 测试用例——覆盖"围栏内含裸引号"场景

**Files:**
- Modify: `.agent/scripts/test-specialized-pipeline.sh`

### Step 1: 理解现有测试结构

查看第 182–222 行（`fenced-output` 场景），该测试验证"散文前言 + 围栏 JSON"的基本修复路径，但所有 JSON 字段均不含裸引号，**不覆盖**本 bug 的触发条件。

需要新增一个场景 `fenced-quotes`：
- 分析师输出：中文散文前言 + ` ```json ` 围栏 + JSON（含裸引号的 summary 和 root_cause 字段）
- 期望结果：pipeline 正常提取 + 修复 + 通过契约校验 + 进入实施阶段 + 最终 complete

### Step 2: 在 `test-specialized-pipeline.sh` 末尾（publish_expr 单元测试之前）追加新场景

找到 `# finalize-round.sh must read publish_changes...` 注释行，在其**之前**插入：

```bash
# Analyst outputs a fenced JSON block preceded by Chinese prose, with bare
# double-quotes inside string values. normalize_agent_json must repair and
# extract the block so the contract check passes and the pipeline proceeds.
fenced_quotes_root="$(setup_scenario fenced-quotes)"
cat >"${fenced_quotes_root}/bin/claude" <<'CLAUDEEOF'
#!/usr/bin/env bash
task="$(cat)"
case "$task" in
  *"analyst phase"*)
    # Chinese prose preamble + fenced block + bare " inside summary/root_cause
    printf '这是对该 issue 的分析：\n\n'
    printf '```json\n'
    printf '%s\n' '{"status":"ready","task_type":"feature","summary":"文件中包含原始内容 \"original\"，需要替换为 \"changed\"。","evidence":["app.txt 当前含 original 字样"],"root_cause_or_rationale":"未执行替换操作，文件仍含 \"original\"。","implementation_plan":["更新 app.txt 内容"],"validation_plan":["grep changed app.txt"],"risks":[]}'
    printf '```\n'
    ;;
  *"implementer phase"*)
    test -s .agent_state/issues/1/analysis.json
    printf 'changed\n' >app.txt
    printf '%s\n' '{"status":"ready_for_verification","summary":"已替换内容。","changes":["app.txt: updated"],"tests":["grep changed app.txt: passed"],"deviations":[],"remaining_concerns":[]}'
    ;;
  *"verifier phase"*)
    test -s .agent_state/issues/1/implementation.json
    grep -q changed app.txt
    printf '%s\n' '{"status":"pass","summary":"内容已验证。","tests":["grep changed app.txt: passed"],"acceptance_checks":["changed: pass"],"findings":[]}'
    ;;
  *"reviewer phase"*)
    test -s .agent_state/issues/1/verification.json
    printf '%s\n' '{"status":"complete","summary":"实施满足需求。","next_step":"合并即可。","tests":["grep changed app.txt: passed"],"findings":[]}'
    ;;
  *) exit 7 ;;
esac
CLAUDEEOF
chmod +x "${fenced_quotes_root}/bin/claude"
run_fake_round "$fenced_quotes_root"
# The pipeline must have repaired the bare-quote JSON and completed normally
test "$(jq -r '.status' "${fenced_quotes_root}/target/.agent_state/issues/1/result.json")" = complete
test -s "${fenced_quotes_root}/target/.agent_state/issues/1/analysis.json"
grep -q changed "${fenced_quotes_root}/target/app.txt"
```

**注意**：fake analyst 输出的 JSON 使用 `\"` 语法（shell `printf` 内部），这些会在写入文件时变成真正的裸 `"`，正确模拟了模型的输出。

### Step 3: 运行测试套件

```bash
bash .agent/scripts/test-specialized-pipeline.sh
```

**修改前期望：** 新的 `fenced_quotes` 场景失败（因为 Python 修复还未加入，或测试写法有误）。

**修改后期望（Task 2 完成后）：**
```
ok: success scenario
ok: verifier-gate scenario
ok: readonly-mutation scenario
ok: protected-state-mutation scenario
ok: credential-leak scenario
ok: fenced-output scenario
ok: already-satisfied scenario
ok: insufficient-evidence scenario
ok: fenced-quotes scenario   ← 新增
ok: publish_changes unit tests
All tests passed.
```

### Step 4: Commit

```bash
git add .agent/scripts/test-specialized-pipeline.sh
git commit -m "test: add fenced-quotes scenario covering bare double-quote repair"
```

---

## Task 4: 顺序验证

**目的：** 确认三项改动整体协作正确，无回归。

### Step 1: 运行完整测试套件

```bash
bash .agent/scripts/test-specialized-pipeline.sh
```

Expected: 所有场景 pass，包括 `fenced-quotes`。

### Step 2: 检查 run-round.sh 语法

```bash
bash -n .agent/scripts/run-round.sh
```

Expected: 无输出。

### Step 3: 确认提示词改动内容正确

```bash
grep -n "bare double-quote\|裸双引号\|bare quotes" \
  .agent/prompts/agent-round.md \
  .agent/prompts/analyst-system.md
```

Expected: 两个文件各有 1 行命中。

### Step 4: 确认 Python 修复块已写入脚本

```bash
grep -n "json.JSONDecodeError\|Last-resort\|PYEOF" .agent/scripts/run-round.sh
```

Expected: 三行命中（注释行 + JSONDecodeError 行 + PYEOF 行）。

---

## 改动范围总结

| 文件 | 修改类型 | 作用 |
|---|---|---|
| `.agent/prompts/agent-round.md` | 追加 1 句 | 所有角色：禁止 JSON 字符串内使用裸 `"` |
| `.agent/prompts/analyst-system.md` | 追加 1 句 | 分析师：同上，并提示使用 `\"` 或 `「」` |
| `.agent/scripts/run-round.sh` | 修改 `normalize_json_candidate` | 新增 Python 迭代修复层（第三层兜底） |
| `.agent/scripts/test-specialized-pipeline.sh` | 追加 `fenced-quotes` 场景 | 覆盖"围栏 + 裸引号"完整修复路径 |

**不需要修改的文件：** `finalize-round.sh`、`analyst-system.md` 的其余部分、所有 `memory.md`、GitHub workflow 文件。
