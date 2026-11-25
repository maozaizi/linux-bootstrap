# Linux 服务器初始化

Debian / Ubuntu 新 VPS 的标准化初始化脚本：基础环境、Swap、BBR、IPv6、UFW、SSH 收口，Docker 可按需安装。
每个组件都能独立运行，`server-init.sh` 只负责调度。

## 快速开始

以 root 登录新 VPS：

```bash
apt update && apt install -y git ca-certificates   # 没有 Git 时
git clone https://github.com/maozaizi/linux-bootstrap.git /root/linux-bootstrap
cd /root/linux-bootstrap
bash server-init.sh          # 显示菜单，只执行选中的一项；回车或 0 退出
```

执行完整初始化需明确指定：

```bash
bash server-init.sh init
# 可预先提供公钥，避免交互粘贴
BOOTSTRAP_PUBKEY_FILE=/root/id_ed25519.pub bash server-init.sh init
BOOTSTRAP_PUBKEY="ssh-ed25519 AAAA... comment" bash server-init.sh init
# 保留 IPv6 / 暂缓关闭 SSH 密码
bash server-init.sh init --keep-ipv6 --defer-ssh-lockdown
```

## 完整初始化流程

| 步骤 | 内容 |
|---|---|
| 1. 预检 | 只读校验系统版本、公钥、软件清单和参数；不通过则不做任何修改 |
| 2. Swap | 内存低于 768MB 且无活动 Swap 时，创建 1G `/swapfile` |
| 3. 基础环境 | 系统更新、`soft-list` 软件、时区与自动校时、运维用户（公钥 + sudo + Zsh）；保留原 SSH 策略 |
| 4. BBR | 启用内核自带 BBR + fq，不替换内核 |
| 5. IPv6 | 关闭 IPv6（通过 IPv6 登录时拒绝执行；`--keep-ipv6` 跳过） |
| 6. 防火墙 | 全新 UFW：默认拒绝入站，放行 SSH 和 `443/tcp`；已有规则只检查不改 |
| 7. SSH 收口 | 展示审计结果；你在新终端验证公钥登录和 `sudo -v` 后输入 `verified`，才关闭密码认证 |

默认运维用户 `maozaizi`，时区 `Asia/Shanghai`。初始化**不会**：安装 Docker、部署节点、写入面板 IP、修改 SSH 端口、自动重启。
Hy2 UDP 等业务端口属于后续部署。

## 组件

| 功能 | 直接运行 | 通过入口运行 |
|---|---|---|
| 基础环境 | `bash bootstrap-debian.sh` | `bash server-init.sh bootstrap` |
| 只装软件清单 | `bash bootstrap-debian.sh --packages-only` | `bash server-init.sh bootstrap --packages-only` |
| 只启用校时 | `bash bootstrap-debian.sh --time-sync-only` | 菜单 9 |
| Swap | `bash setup-swap.sh` | `bash server-init.sh swap` |
| BBR | `bash enable-bbr.sh` | `bash server-init.sh bbr` |
| IPv6 | `bash ipv6-manager.sh status` | `bash server-init.sh ipv6 status` |
| 防火墙 | `bash ufw-manager.sh check` | `bash server-init.sh firewall check` |
| 只读审计 | `bash server-security-audit.sh --audit-only` | `bash server-init.sh audit --audit-only` |
| SSH 收口 | `bash server-security-audit.sh` | `bash server-init.sh audit` |
| Docker | `bash install-docker.sh -u maozaizi` | `bash server-init.sh docker -u maozaizi` |

参数原样转交给组件；各脚本的 `--help` 列出全部选项。

## 常用配置（环境变量）

| 变量 | 默认值 | 作用 |
|---|---|---|
| `BOOTSTRAP_USER` | `maozaizi` | 运维用户名 |
| `BOOTSTRAP_TZ` | `Asia/Shanghai` | 时区 |
| `BOOTSTRAP_PUBKEY` / `BOOTSTRAP_PUBKEY_FILE` | 交互输入 | 运维用户的单行 SSH 公钥 |
| `SOFT_LIST_FILE` | 同目录 `soft-list` | 软件清单 |
| `APT_LOCK_TIMEOUT` | `300` | apt 等待 dpkg 锁的秒数（新机自动更新常占锁） |
| `SSH_PORT` | 空 = 保持当前端口 | 仅单独运行 bootstrap 的 SSH 加固时生效：写入端口并同步 `ssh.socket` |
| `RESTRICT_SSH_USERS` | `0` | 设为 `1` 时写入 `AllowUsers`，只允许运维用户和 root 登录 SSH |

## 软件清单 `soft-list`

- 每行一个包名，支持空行和 `#` 注释；清单只当数据读取，不会执行。
- 格式错误、为空或含卸载写法（如 `sudo-`）时，在任何修改前停止；安装使用 `--no-remove`，不会删除软件。
- 新增条目下次应用时安装；删除条目不会卸载已装软件。
- `ping` 优先保留已安装的 `inetutils-ping`，否则用 `iputils-ping`；需要指定实现就写具体包名。

## 安全行为

- **apt**：等待 dpkg 锁；升级遇到配置文件冲突时保留现有配置，不弹出提示；每次运行安装前刷新软件源。
- **SSH**：完整初始化保留当前端口和登录策略。收口只关闭密码和键盘交互认证，不改 root 登录限制。
  收口前确认至少有一个账户已有可用公钥，验证或重载失败时自动恢复原配置。
- **单独运行 bootstrap 的 SSH 加固**：不设 `SSH_PORT` 就保留当前端口，端口会变化时停止并回滚；
  默认不写 `AllowUsers`，避免挡住服务商默认账户。
- **文件写入**：公钥和用户 Shell 配置以目标用户身份写入，拒绝符号链接；首次覆盖 `/etc/zsh/zshrc` 前备份为 `zshrc.bootstrap-orig`。
- **防火墙**：UFW 重建前完整备份到 `/var/backups/ufw-manager/`，失败时恢复。Docker 发布的端口不受 UFW 约束，`check` 会提示。

## 失败与重跑

- 初始化加锁，防止重复运行；日志保存在 `/var/log/server-init-日期-时间.log`。
- 任一步骤失败立即停止。SSH、IPv6、UFW 有局部回滚；已完成的软件安装和更新不会撤销。
- 修复后重新执行即可：已完成的步骤会跳过，用户、公钥、软件清单和校时会重新检查。
- 最终输出会分别列出 SSH 收口和时间同步状态，“基础初始化完成”不代表所有待办都已处理。
- Zsh 在重新登录后生效；当前终端需要时手动执行 `exec zsh -l`。

## 支持的系统

- 已验证：Ubuntu 22.04 / 24.04 / 26.04 LTS，Debian 12 / 13。
- 其他 Debian ≥ 12、Ubuntu ≥ 22.04 的版本：警告后继续。更低版本或其他发行版：直接停止。
- 运行要求：root、Bash 4+、systemd、交互终端。

## 在 VPS 上更新

```bash
git -C /root/linux-bootstrap pull --ff-only
```

拉取只更新脚本，不改服务器配置；要应用哪项更新，就单独运行对应组件。
服务器自己的配置放在仓库目录以外，避免更新冲突。需要固定版本时检出发布标签（如 `v1.3.0`）。

## 维护与发布

**本地检查**（不修改宿主机）：

```bash
for f in *.sh tests/*.sh; do bash -n "$f"; done
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v

# 一次性容器：只读预检 + 软件清单可安装性（apt-get -s）
for img in debian:12 debian:13 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04; do
  docker run --rm -v "$PWD:/src:ro" "$img" bash /src/tests/container-smoke.sh
done
```

**CI**：`.github/workflows/ci.yml` 在每个 PR 和 `main` 的推送上运行语法检查、ShellCheck（error 级别）、单元测试和上述五个发行版的冒烟测试。
这些检查不能替代真实服务器上的部署验收。

**发布流程**：

1. 新建分支修改，更新相关脚本的 `Version` 头和简短说明，并在 `CHANGELOG.md` 记录。
2. 检查差异中没有密钥、密码、真实服务器地址；提交使用 GitHub 隐私邮箱。
3. 推送分支并开 PR；CI 通过、review 后合并到 `main`，不直接推送 `main`。
4. 需要固定版本时，在合并后的 `main` 上打标签。

真实服务器配置、凭据和日志放在 `local/` 等已忽略的目录中。
