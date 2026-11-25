# 更新记录

更早的版本见 [GitHub Releases](https://github.com/maozaizi/linux-bootstrap/releases)。

## v1.3.0

**稳定性**
- apt 等待 dpkg 锁（`APT_LOCK_TIMEOUT`，默认 300 秒），新机自动更新期间不再直接失败。
- 升级遇到配置文件冲突时保留现有配置，不再停下询问。
- 每次运行安装前刷新软件源，重跑时不再使用过期列表。

**行为变化**
- 单独运行 bootstrap 的 SSH 加固时，`SSH_PORT` 默认保持当前端口（以前写死为 22）。
- `AllowUsers` 改为 `RESTRICT_SSH_USERS=1` 时才写入。⚠️ 用旧版跑过加固的机器，重跑后会去掉该限制。
- 未验证的 Debian ≥ 12 / Ubuntu ≥ 22.04 版本改为警告后继续（以前直接拒绝）。

**其他**
- 首次覆盖 `/etc/zsh/zshrc` 前备份原文件。
- 新增 GitHub Actions CI 和容器冒烟测试；发布流程改为分支 + PR。

组件版本：bootstrap-debian.sh 1.8.0 · server-init.sh 1.2.0 · install-docker.sh 1.6.0
