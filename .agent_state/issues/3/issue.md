# Issue #3: [Agent] 验证流水线可产出真实代码改动

- URL: https://github.com/dustPyrotechnic/agent-cycle-test/issues/3
- Author association: OWNER
- Labels: solve-it

## Body

## 任务类型

Feature

## 目标

验证有界代理流水线能够针对一个真实、可验证的小增量完成一轮工作，并通过 Pull Request 发布改动。本轮要求 `install.sh` 支持 `--help`/`-h` 参数：打印用法说明后以退出码 0 结束，不执行任何安装副作用。

## 复现与证据

当前 `install.sh` 没有帮助入口，新用户无法在不触发安装逻辑的情况下查看用法。

## 验收检查

- `bash install.sh --help` 打印用法说明并以退出码 0 退出。
- `bash install.sh -h` 行为与 `--help` 一致。
- `--help` 路径不创建、修改或删除任何文件。
- `shellcheck install.sh .agent/scripts/*.sh` 通过。
- `bash .agent/scripts/validate.sh` 通过。

## 约束与上下文

- 仅修改 `install.sh`。不要改动 `.agent/`、`.github/` 或根级文档。
- 保持现有安装行为不变，帮助逻辑应在参数解析最前面短路返回。
- 不要打印或读取任何密钥与令牌。
