# Issue #24: [矩阵-真feature] README 未说明无效 issue 的算命证据闸门

- URL: https://github.com/dustPyrotechnic/agent-cycle-test/issues/24
- Author association: OWNER
- Labels: 

## Body

## 背景
本引擎对完全无有效信息的 issue 会走 insufficient_evidence 路径，由分析师用赛博算命 skill 回复并要求补充材料，不进入实施器、不建 PR（见 .agent/prompts/analyst-system.md 与 .agent/skills/cyber-divination-debug/）。

## 问题
README.md 完全没有向使用者说明这一行为。

## 证据（可复现）
```
grep -ciE "算命|insufficient|无效 issue|起卦" README.md
# 0
```

## 期望
在 README.md 增加一小节，简述：无效/信息不足的 issue 会被分析师以算命式回复要求补充日志、截图、复现步骤、环境与版本，且不会产生代码改动或 PR。

## 验收
README.md 中包含对该 insufficient_evidence 行为的说明。
