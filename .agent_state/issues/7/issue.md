# Issue #7: install.sh 增加 --version/-V 选项

- URL: https://github.com/dustPyrotechnic/agent-cycle-test/issues/7
- Author association: OWNER
- Labels: 

## Body

## 目标

让 `install.sh` 支持 `--version`/`-V`：打印安装器版本号后以退出码 0 结束，不执行任何安装副作用。本 issue 未打任何标签，用于验证「新建任意 issue 即自动触发代理」。

## 验收检查

- `bash install.sh --version` 打印版本字符串并以退出码 0 退出。
- `bash install.sh -V` 行为与 `--version` 一致。
- `--version` 路径不创建/修改/删除任何文件，也不调用 gh/git 网络操作。
- 用法文本（usage）新增 `--version`/`-V` 说明。
- `shellcheck install.sh .agent/scripts/*.sh` 通过。
- `bash .agent/scripts/validate.sh` 通过。

## 约束

- 仅修改 `install.sh`。版本处理在参数解析最前面短路返回。不要打印或读取任何密钥。
