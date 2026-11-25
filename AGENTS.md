# 维护约定

- 当前目录是维护源，GitHub 仓库为 `maozaizi/linux-bootstrap`，默认分支 `main`。
- 保持 Shell 脚本独立、简单；修改脚本时更新版本号和简短注释，文件开头保留基础用法。
- 修改前检查 Git 状态，保留用户已有改动；仅暂存本次确认要发布的文件。
- 提交前检查差异中的密钥、密码、公钥、真实服务器地址和个人信息。
- 脚本变更后检查 Bash 语法，并运行 `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`；不在本机执行服务器初始化。
- 发行版相关改动另用一次性容器运行 `tests/container-smoke.sh`（见 README）；CI 会在 PR 上自动执行全部检查。
- 发布统一走“新分支 + Pull Request”：在功能分支提交并推送，开 PR，由维护者 review 并合并；不直接推送 `main`，不自行合并。
- 确认 CI 结果后再报告；不得将失败的推送或未通过的检查报告为已完成。
- 使用 GitHub 隐私邮箱提交。不强制推送；认证失败或远端存在冲突时，保留改动并说明阻碍。
- 发布只更新仓库，不自动在 VPS 上运行脚本；固定版本通过发布标签提供，标签在 PR 合并后打在 `main` 上。
