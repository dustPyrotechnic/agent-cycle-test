# Issue #5: [Agent] install.sh 增加 --version/-V 选项

- URL: https://github.com/dustPyrotechnic/agent-cycle-test/issues/5
- Author association: OWNER
- Labels: solve-it

## Body

## 任务类型

Feature

## 目标

验证修复后的流水线能针对一个需要真实代码改动的任务跑完整条链路并发布 PR。本轮要求 `install.sh` 支持 `--version`/`-V`：打印安装器版本号后以退出码 0 结束，不执行任何安装副作用。

## 复现与证据

当前 `install.sh` 的选项里有 `-h, --help`（见用法文本），但没有任何查看版本的入口，用户无法确认所用安装器版本。

## 验收检查

- `bash install.sh --version` 打印一个版本字符串并以退出码 0 退出。
- `bash install.sh -V` 行为与 `--version` 一致。
- `--version` 路径不创建、修改或删除任何文件，也不调用 gh/git 网络操作。
- 用法文本（usage）中新增对 `--version`/`-V` 的说明。
- `shellcheck install.sh .agent/scripts/*.sh` 通过。
- `bash .agent/scripts/validate.sh` 通过。

## 约束与上下文

- 仅修改 `install.sh`。不要改动 `.agent/`、`.github/` 或根级文档。
- 版本处理应在参数解析最前面短路返回，先于任何依赖检查或文件写入。
- 保持现有安装行为不变。不要打印或读取任何密钥与令牌。
