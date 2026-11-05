#!/usr/bin/env bash
# 统一调度入口；所有组件仍可直接通过 bash 单独运行。
# Version: 1.0.3 | Updated: 2026-11-05
# 用法（root）：bash server-init.sh；按提示提供公钥并完成初始化。
# 保留 IPv6：bash server-init.sh --keep-ipv6；其他选项见 --help。
# 按需安装 Docker：bash server-init.sh docker -u maozaizi。
set -Eeuo pipefail
export PATH="${PATH}:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
CURRENT_STEP="预检"
KEEP_IPV6=0
DEFER_SSH=0

log() {
  printf '[INFO] %s\n' "$*"
  if [[ -n "${LOG_FILE:-}" ]]; then printf '[INFO] %s\n' "$*" >> "$LOG_FILE"; fi
}
die() {
  printf '[ERROR] %s\n' "$*" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then printf '[ERROR] %s\n' "$*" >> "$LOG_FILE"; fi
  exit 1
}
stop_on_failure() {
  local rc="$1" message
  message="步骤「${CURRENT_STEP}」失败（退出码 ${rc}），已停止。已完成的步骤不会自动撤销。"
  printf '[ERROR] %s\n' "$message" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then printf '[ERROR] %s\n' "$message" >> "$LOG_FILE"; fi
  exit "$rc"
}
trap 'stop_on_failure "$?"' ERR

usage() {
  cat <<'EOF'
用法：
  bash server-init.sh [init] [--keep-ipv6] [--defer-ssh-lockdown]
      交互式初始化；公钥可通过提示、BOOTSTRAP_PUBKEY 或 BOOTSTRAP_PUBKEY_FILE 提供。
      默认：基础环境、低内存 Swap、BBR、关闭 IPv6、UFW、验证登录后关闭 SSH 密码。
      --keep-ipv6           保留 IPv6（通过 IPv6 登录时必须使用）
      --defer-ssh-lockdown  暂不关闭 SSH 密码，稍后单独运行 audit

  bash server-init.sh docker [-u USER] [-S] [-L]
  bash server-init.sh bootstrap [组件参数...]
  bash server-init.sh swap [组件参数...]
  bash server-init.sh bbr [组件参数...]
  bash server-init.sh ipv6 [组件参数...]
  bash server-init.sh firewall [组件参数...]
  bash server-init.sh audit [组件参数...]
      转交给对应的独立脚本，不增加默认参数。

配置沿用组件环境变量；默认运维用户 maozaizi，时区 Asia/Shanghai。
统一初始化保留当前 SSH 端口；如需变更，请单独配置并验证端口与防火墙。
初始化不安装 Docker、不部署 Node、不设置面板来源 IP，也不自动重启服务器。
EOF
}

run_component() {
  local script="$1"
  shift
  [[ -r "$SCRIPT_DIR/$script" ]] || die "缺少组件：${script}；请保持整个项目目录完整。"
  CURRENT_STEP="$script"
  log "执行 $script $*"
  # 不放入 if / || 中，保留组件自身的失败退出行为。
  if [[ -n "${LOG_FILE:-}" ]]; then
    bash "$SCRIPT_DIR/$script" "$@" 2>&1 | tee -a "$LOG_FILE"
  else
    bash "$SCRIPT_DIR/$script" "$@"
  fi
}

confirm() {
  local answer
  read -r -p "$1 [y/N]: " answer || return 1
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]]
}

# sudo 可能清理 SSH_CONNECTION，沿父进程读取原连接信息。
ssh_context() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then printf '%s' "$SSH_CONNECTION"; return; fi
  local pid="$PPID" value attempt=0
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 && attempt < 32 )); do
    if [[ -r "/proc/$pid/environ" ]]; then
      value="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^SSH_CONNECTION=//p')"
      if [[ -n "$value" ]]; then printf '%s' "$value"; return; fi
    fi
    pid="$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
    attempt=$((attempt + 1))
  done
  return 0
}

preflight() {
  [[ "$(uname -s)" == Linux && "$EUID" -eq 0 ]] || die "初始化需在 Linux 服务器上以 root 执行。"
  (( BASH_VERSINFO[0] >= 4 )) || die "需要 Bash 4 或更新版本。"
  [[ -t 0 && -t 1 ]] || die "初始化需要交互终端；请先保存整个目录后执行。"
  [[ -d /run/systemd/system ]] || die "初始化需要正在运行的 systemd。"
  local id version cmd script
  id="$(. /etc/os-release; printf '%s' "$ID")"
  version="$(. /etc/os-release; printf '%s' "$VERSION_ID")"
  case "$id:$version" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
    *) die "仅支持 Ubuntu 22.04/24.04 和 Debian 12/13。" ;;
  esac
  for cmd in ssh-keygen systemctl flock tee awk tr sed; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少必要命令：$cmd"
  done
  for script in bootstrap-debian.sh setup-swap.sh enable-bbr.sh ipv6-manager.sh ufw-manager.sh server-security-audit.sh; do
    [[ -r "$SCRIPT_DIR/$script" ]] || die "缺少组件：$script"
  done
  export SSH_CONNECTION="$(ssh_context)"
  if (( KEEP_IPV6 == 0 )) && [[ "${SSH_CONNECTION:-}" == *:* ]]; then
    die "当前 SSH 连接使用 IPv6，请追加 --keep-ipv6，避免断开远程入口。"
  fi
}

collect_key() {
  if [[ -z "${BOOTSTRAP_PUBKEY:-}" && -z "${BOOTSTRAP_PUBKEY_FILE:-}" ]]; then
    read -r -p '请粘贴单行 SSH 公钥，或输入服务器上的公钥文件路径：' BOOTSTRAP_PUBKEY
    if [[ -f "$BOOTSTRAP_PUBKEY" ]]; then
      BOOTSTRAP_PUBKEY_FILE="$BOOTSTRAP_PUBKEY"
      BOOTSTRAP_PUBKEY=""
    fi
  fi
  # 由 Bootstrap 自身完成完整公钥与配置预检；入口不复制校验逻辑。
  export BOOTSTRAP_PUBKEY="${BOOTSTRAP_PUBKEY:-}"
  export BOOTSTRAP_PUBKEY_FILE="${BOOTSTRAP_PUBKEY_FILE:-}"
}

setup_firewall() {
  local status rules
  status="$(LC_ALL=C ufw status)"
  rules="$(LC_ALL=C ufw show added)"
  # 实际规则以 ufw 开头；说明文字中的 ufw status 不算规则。
  if [[ "$status" == *'Status: active'* ]] || grep -q '^ufw ' <<< "$rules"; then
    log '检测到已有防火墙配置，保留规则并检查；不会自动 reset 或扩大放行范围。'
    run_component ufw-manager.sh check
    [[ "$status" == *'Status: active'* ]] || die '已有 UFW 规则尚未启用，请检查规则并手动启用后重跑初始化。'
  else
    run_component ufw-manager.sh init --yes
  fi
}

setup_swap() {
  local memory
  memory="$(awk '/^MemTotal:/ {printf "%.0f", $2 / 1024}' /proc/meminfo)"
  if awk 'NR > 1 {found=1} END {exit !found}' /proc/swaps; then
    log '已有活动 Swap，保留现状；如需调整可单独运行 setup-swap.sh。'
  elif (( memory < 768 )); then
    run_component setup-swap.sh --yes
  else
    log "内存 ${memory}MB，无需按 SOP 自动创建 Swap。"
  fi
}

finish_security() {
  local answer
  run_component server-security-audit.sh --audit-only
  if (( DEFER_SSH == 1 )); then
    log 'SSH 密码策略保持原状；验证登录后可单独执行 bash server-init.sh audit。'
    return 0
  fi
  printf '\n请保持当前会话，在新终端用公钥登录 %s，并执行 sudo -v。\n' "$BOOTSTRAP_USER"
  read -r -p '两项均成功后，输入 verified 关闭所有 SSH 密码认证；回车暂缓：' answer
  if [[ "$answer" == verified ]]; then
    run_component server-security-audit.sh --yes
    log 'SSH 公钥认证收口完成。'
  else
    log 'SSH 收口尚未完成，密码策略保持原状；验证后单独执行 bash server-init.sh audit。'
  fi
}

initialize() {
  while (($#)); do
    case "$1" in
      --keep-ipv6) KEEP_IPV6=1 ;;
      --defer-ssh-lockdown) DEFER_SSH=1 ;;
      *) die "未知初始化选项：$1" ;;
    esac
    shift
  done
  preflight
  collect_key
  export BOOTSTRAP_USER="${BOOTSTRAP_USER:-maozaizi}"
  export BOOTSTRAP_TZ="${BOOTSTRAP_TZ:-Asia/Shanghai}"
  printf '\n用户：%s；时区：%s；IPv6：%s\n' "$BOOTSTRAP_USER" "$BOOTSTRAP_TZ" "$([[ "$KEEP_IPV6" == 1 ]] && echo 保留 || echo 关闭)"
  log '将执行预检 → 按需 Swap → Bootstrap → BBR → IPv6 → UFW → SSH 登录验证与收口。'
  confirm '开始初始化？' || { log '已取消。'; return 0; }

  exec 9>/run/lock/linux-bootstrap.lock
  flock -n 9 || die "另一个初始化进程正在运行。"
  LOG_FILE="/var/log/server-init-$(date +%Y%m%d-%H%M%S).log"
  (umask 077; : > "$LOG_FILE")
  log "本次日志：$LOG_FILE"

  # 先只读校验，再为低内存机器准备 Swap，最后执行更新和安装。
  FORCE_RUN=1 HARDEN_SSH=0 SET_ROOT_SHELL_ZSH=1 run_component bootstrap-debian.sh --check
  setup_swap
  FORCE_RUN=1 HARDEN_SSH=0 SET_ROOT_SHELL_ZSH=1 run_component bootstrap-debian.sh
  run_component enable-bbr.sh
  if (( KEEP_IPV6 == 0 )); then run_component ipv6-manager.sh disable; fi
  setup_firewall
  finish_security
  log '基础初始化完成。Docker 和 Node 按需另行部署；未自动重启。'
  [[ ! -e /var/run/reboot-required ]] || log '系统提示需要重启，请确认新用户登录成功后自行安排。'
}

main() {
  local action="${1:-init}" script
  (($# == 0)) || shift
  case "$action" in
    -h|--help|help) usage ;;
    --version|version) printf 'server-init.sh 1.0.3\n' ;;
    init) initialize "$@" ;;
    --keep-ipv6|--defer-ssh-lockdown) initialize "$action" "$@" ;;
    bootstrap) script=bootstrap-debian.sh ;;
    swap) script=setup-swap.sh ;;
    bbr) script=enable-bbr.sh ;;
    ipv6) script=ipv6-manager.sh ;;
    firewall) script=ufw-manager.sh ;;
    audit) script=server-security-audit.sh ;;
    docker) script=install-docker.sh ;;
    *) die "未知命令：${action}；使用 --help 查看用法。" ;;
  esac
  if [[ -n "${script:-}" ]]; then run_component "$script" "$@"; fi
}

main "$@"
