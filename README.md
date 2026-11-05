# Linux 服务器初始化

新 VPS 以 root 执行，先下载，再从菜单选择操作：

```bash
git clone https://github.com/maozaizi/linux-bootstrap.git /root/linux-bootstrap
cd /root/linux-bootstrap
bash server-init.sh
```

若没有 Git，先执行 `apt update && apt install -y git ca-certificates`。下载公开仓库无需登录 GitHub。

不带参数只显示菜单，选择一项后执行并退出；回车或输入 `0` 退出，不会自动执行整套初始化。
菜单提供基础环境、Swap、BBR、IPv6、防火墙、Docker、只读审计、SSH 收口和单独校时。
基础环境会配置 root 和运维用户的 Zsh，保留原 SSH 策略；防火墙默认检查，选择 `init` 才进入重建确认。
确认重建后，入口才向 UFW 组件传入 `--yes`；取消不改动规则。

需要完整流程时，明确执行：

```bash
bash server-init.sh init
```

基础环境或完整初始化会要求提供公钥，需要设置运维用户密码时会要求输入两次。
也可以通过环境变量提供公钥；例如执行完整流程：

```bash
BOOTSTRAP_PUBKEY_FILE=/root/id_ed25519.pub bash server-init.sh init
# 也支持直接提供完整单行公钥
BOOTSTRAP_PUBKEY="ssh-ed25519 完整公钥内容" bash server-init.sh init
```

默认运维用户 `maozaizi`，时区 `Asia/Shanghai`。完整初始化依次执行：

1. 只读预检：校验公钥、软件清单和初始化参数。
2. 内存低于 768MB 且没有活动 Swap 时，先创建默认 1G Swap。
3. Bootstrap：系统更新、工具、时区与自动校时、运维用户、公钥、sudo、Zsh 与历史记录，保留原 SSH 策略。
4. 启用原生 BBR；不替换内核。
5. 关闭 IPv6；通过 IPv6 登录时拒绝此操作。
6. 全新 UFW 放行 SSH 与 `443/tcp`；已有规则保留。已配置但未启用时停止，交由操作者处理。
7. 展示审计结果；在新终端验证运维用户公钥登录和 `sudo -v` 后，输入 `verified` 关闭 SSH 密码认证。

不安装 Docker、不部署 Node、不写入面板 IP、不自动重启。Hy2 UDP 端口及节点管理端口属于后续业务部署。
统一初始化保留当前 SSH 监听端口；需要变更端口时，请单独配置并验证防火墙与新连接。
已有防火墙配置仅检查，不能据此认定它已符合上述新机策略。

## 软件包清单

基础软件包统一维护在同目录的 `soft-list`：每行一个包名，支持空行、`#` 注释和行尾注释。
基础工具按清单交给 apt，依赖和虚拟包由 apt 自行处理；自动校时服务另按下节按需补齐。
清单缺失、为空或包名格式错误时，在系统变更前停止。清单作为数据读取，不执行其中内容。
清单拒绝 `sudo-` 等卸载操作符，安装命令使用 `--no-remove` 阻止删除软件包；包是否可用由 apt 校验。

修改后，以 root 单独应用清单即可，无需公钥或重跑其他初始化步骤：

```bash
bash bootstrap-debian.sh --packages-only
# 等价入口
bash server-init.sh bootstrap --packages-only

# 按需使用其他清单
SOFT_LIST_FILE=/root/custom-soft-list bash bootstrap-debian.sh --packages-only
```

新增条目在下次应用时安装；删除条目不会自动卸载已有软件。
已有安装完成标记不会跳过这项操作。apt 仍可能更新清单中已安装的软件包。
单独运行 Bootstrap 时，请同时保留 `soft-list`，或通过 `SOFT_LIST_FILE` 指定文件。

Debian 13 中，`dnsutils` 由 `bind9-dnsutils` 提供，`libncursesw5-dev` 由 `libncurses-dev` 提供。
这是发行版的包提供关系，清单保留原名称；对应软件已安装时，不应仅按旧包名判断为漏装。

## 自动校时与 Shell 生效

初始化优先保留已运行的常见校时服务；有可用服务时直接启用，无可用服务时才安装 `systemd-timesyncd`。
按需安装使用 `--no-remove`，不会为校时移除已有软件，也不覆盖现有时间源配置。
服务启动和首次同步是两件事；尚未同步时会明确提示待检查，不会无限等待或误报同步完成。
原有步骤标记不跳过校时检查；只安装软件清单不会启用校时。

已经初始化过的服务器可更新代码后，以 root 单独执行，无需公钥或重跑其他步骤：

```bash
bash bootstrap-debian.sh --time-sync-only
timedatectl status
```

Zsh 默认登录 Shell 与配置在重新登录后生效。需要当前终端立即切换时，手动执行 `exec zsh -l`。
脚本不会替换调用它的外层终端。

## 可选设置

```bash
# 保留 IPv6；暂缓 SSH 密码收口
bash server-init.sh --help
bash server-init.sh init --keep-ipv6 --defer-ssh-lockdown

# 沿用组件环境变量
BOOTSTRAP_USER=ops BOOTSTRAP_TZ=Asia/Shanghai bash server-init.sh

# 日后按需安装 Docker
bash server-init.sh docker -u maozaizi
```

## 组件保持独立

| 功能 | 直接运行 | 通过入口运行 |
|---|---|---|
| 基础环境 | `bash bootstrap-debian.sh` | `bash server-init.sh bootstrap` |
| Swap | `bash setup-swap.sh` | `bash server-init.sh swap` |
| BBR | `bash enable-bbr.sh` | `bash server-init.sh bbr` |
| IPv6 | `bash ipv6-manager.sh status` | `bash server-init.sh ipv6 status` |
| 防火墙 | `bash ufw-manager.sh check` | `bash server-init.sh firewall check` |
| 只读审计 | `bash server-security-audit.sh --audit-only` | `bash server-init.sh audit --audit-only` |
| SSH 收口 | `bash server-security-audit.sh` | `bash server-init.sh audit` |
| Docker | `bash install-docker.sh -u maozaizi` | `bash server-init.sh docker -u maozaizi` |

所有组件参数原样转交，各脚本不依赖入口。直接运行组件时仍需遵守自身的公钥、权限与确认要求。
SSH 收口只限制认证方式，不重写原有 root 登录限制；原先禁止 root 登录时仍保持禁止。
升级旧版收口文件时，也保留其中的 root 策略及来源限制。
IPv6 状态按实际接口显示，可能为混合状态；交互模式可明确选择关闭或开启。
Docker 的 `-L` 日志参数在安装、卸载和配置修改前校验，错误参数会直接停止。

## 失败与重跑

初始化用锁避免同时运行，日志保存在 `/var/log/server-init-日期-时间.log`。
任何步骤失败立即停止；已经完成的包安装、更新等操作不会整体撤销。
SSH 和 IPv6 配置操作提供局部失败恢复，恢复服务仍失败时会明确提示人工检查。
UFW 重建前备份配置和原启用状态，失败时尝试恢复；完整备份保存在 `/var/backups/ufw-manager/`。
`restrict` 读取或删除规则失败、仍有公网规则覆盖时停止，不会自动删除影响其他端口的范围规则。
低内存 Swap 在系统更新之前准备；之后取消密码输入或发生错误，不会自动撤销已准备的 Swap。

修复问题后再次执行入口。Bootstrap 保留已有步骤标记，但重新检查用户与公钥；
已有 Swap 和防火墙规则不会自动替换。若暂缓 SSH 收口，程序会明确提示，该步骤仍需日后完成。
最终结果分别列出 SSH 收口和时间同步状态；“基础初始化完成”不代表所有待办都已完成。

支持 Ubuntu 22.04/24.04、Debian 12/13，要求 root、Bash 4+、systemd 和交互终端。
关闭密码认证前的真实登录验证不能用本机静态检查代替。

## 隐私

通过服务器上的文件或环境变量提供公钥和业务密钥。
真实服务器配置、凭据和日志请保存在 `local/` 等忽略目录，提交前检查文件列表。

## 本地回归检查

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

测试使用临时目录、真实 OpenSSH 配置解析与模拟服务命令，不配置宿主机。
它不能替代目标 Linux 服务器上的完整部署验收。

## 更新与发布

本地维护使用当前项目目录。修改后更新相关脚本的版本和简短注释，检查隐私信息并运行上述回归检查，再提交发布：

```bash
git status
git diff
git add -A
git diff --cached
git commit -m "说明本次更新"
git push origin main
```

提交前检查新增文件，确保没有真实密钥、密码或服务器配置。发布使用 GitHub 隐私邮箱。
需要固定一批服务器使用同一版本时，使用发布标签；首个基础版本为 `v1.0.0`。

VPS 上更新脚本：

```bash
git -C /root/linux-bootstrap pull --ff-only
```

拉取只更新脚本文件，不自动改变服务器配置。需要应用哪项更新，就单独执行对应脚本。
请将服务器自己的配置保存在仓库目录以外，避免更新冲突。
