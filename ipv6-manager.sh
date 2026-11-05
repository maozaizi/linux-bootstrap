#!/usr/bin/env bash
# ipv6-manager.sh — 独立管理 IPv6；不重载其他 sysctl 参数，不修改 GRUB。
# Version: 1.1.1 | Updated: 2026-11-05
# 用法（root）：bash ipv6-manager.sh status；无参数进入交互模式。
# 关闭：bash ipv6-manager.sh disable；恢复：bash ipv6-manager.sh enable。
# 排查其他配置：bash ipv6-manager.sh check；更多说明见 help。
# 配置保存在 /etc/sysctl.d/99-ipv6-manager.conf，变更失败恢复原配置和运行值。

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="1.1.1"

SYSCTL_FILE="/etc/sysctl.d/99-ipv6-manager.conf"
BACKUP_DIR="/etc/sysctl.d/ipv6-manager-backup"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

###############################################################################
# Basic output helpers
###############################################################################

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

###############################################################################
# Permission check
###############################################################################

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 权限运行，例如：sudo ./${SCRIPT_NAME}"
    fi
}

###############################################################################
# IPv6 capability and runtime status
###############################################################################

ipv6_kernel_available() {
    [[ -d /proc/sys/net/ipv6 ]]
}

ipv6_runtime_enabled() {
    if ! ipv6_kernel_available; then
        return 1
    fi

    if [[ ! -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        return 1
    fi

    local value
    value="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)"

    # 0 = IPv6 enabled
    # 1 = IPv6 disabled
    [[ "$value" == "0" ]]
}

###############################################################################
# Show IPv6 status
###############################################################################

show_status() {
    echo
    echo "========== IPv6 当前状态 =========="

    if ! ipv6_kernel_available; then
        echo "IPv6 内核状态：不可用或未加载"
        echo
        warn "当前系统看起来没有可用的 IPv6 内核配置目录。"
        warn "可能是内核不支持 IPv6，或者 IPv6 已通过更底层方式禁用。"
        echo "=================================="
        echo
        return
    fi

    if ipv6_runtime_enabled; then
        echo "运行时 IPv6 状态：已开启"
    else
        echo "运行时 IPv6 状态：已关闭"
    fi

    echo
    echo "关键 sysctl 状态："

    for key in \
        net.ipv6.conf.all.disable_ipv6 \
        net.ipv6.conf.default.disable_ipv6 \
        net.ipv6.conf.lo.disable_ipv6
    do
        sysctl "$key" 2>/dev/null || true
    done

    echo
    if [[ -f "$SYSCTL_FILE" ]]; then
        echo "本脚本管理的持久化配置：存在"
        echo "配置文件路径：$SYSCTL_FILE"
    else
        echo "本脚本管理的持久化配置：不存在"
    fi

    echo "=================================="
    echo
}

# 保持脚本独立执行；sudo 丢失的连接信息从父进程恢复。
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

# 以 /proc/sys 路径访问接口参数，兼容名称带点的网卡。
change_ipv6() (
    value="$1"
    ipv6_kernel_available || error "内核未提供 IPv6 sysctl，无法管理。"
    SSH_CONNECTION="$(ssh_context)"
    if [[ "$value" == 1 && "${SSH_CONNECTION:-}" == *:* ]]; then
        error "当前 SSH 连接使用 IPv6，拒绝关闭 IPv6。请通过 IPv4 或控制台操作。"
    fi
    workdir="$(mktemp -d)"
    committed=0 changed=0 candidate=""
    managed_file_existed=0
    rollback_ipv6() {
        local rc=$? path previous failed=0
        trap - EXIT
        if [[ "$committed" == 0 && "$changed" == 1 ]]; then
            while IFS=' ' read -r path previous; do
                [[ -f "$path" ]] || continue
                printf '%s\n' "$previous" > "$path" || failed=1
            done < "$workdir/runtime"
            if [[ "$managed_file_existed" == 1 ]]; then
                cp -p "$workdir/original" "$SYSCTL_FILE" || failed=1
            else
                rm -f "$SYSCTL_FILE" || failed=1
            fi
            warn "IPv6 操作失败，已尝试恢复原配置与运行值。"
        fi
        if [[ -n "${candidate:-}" && -f "$candidate" ]]; then rm -f "$candidate"; fi
        if [[ "$failed" == 1 ]]; then
            warn "回滚未全部完成，请检查系统；备份保留在 $workdir"
        else
            rm -rf -- "$workdir"
        fi
        exit "$rc"
    }
    trap rollback_ipv6 EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ ! -L "$SYSCTL_FILE" ]] || error "拒绝替换符号链接：$SYSCTL_FILE"
    if [[ -f "$SYSCTL_FILE" ]]; then
        cp -p "$SYSCTL_FILE" "$workdir/original"
        managed_file_existed=1
    fi
    : > "$workdir/runtime"
    for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [[ -f "$path" && -w "$path" ]] || error "IPv6 参数不可写：$path"
        printf '%s %s\n' "$path" "$(cat "$path")" >> "$workdir/runtime"
    done
    [[ -s "$workdir/runtime" ]] || error "未找到可管理的 IPv6 接口。"
    changed=1
    while IFS=' ' read -r path previous; do
        printf '%s\n' "$value" > "$path"
    done < "$workdir/runtime"
    while IFS=' ' read -r path previous; do
        [[ "$(cat "$path")" == "$value" ]] || error "IPv6 运行值未生效：$path"
    done < "$workdir/runtime"
    if [[ "$managed_file_existed" == 1 ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -p "$workdir/original" "$BACKUP_DIR/99-ipv6-manager.conf.$TIMESTAMP.$$.bak"
    fi
    if [[ "$value" == 1 ]]; then
        install -d -m 755 "$(dirname "$SYSCTL_FILE")"
        candidate="$(mktemp "${SYSCTL_FILE}.XXXXXX")"
        printf '# Managed by ipv6-manager.sh\nnet.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\nnet.ipv6.conf.lo.disable_ipv6=1\n' > "$candidate"
        chmod 644 "$candidate"
        mv -f "$candidate" "$SYSCTL_FILE"
    else
        rm -f "$SYSCTL_FILE"
    fi
    committed=1
    log "IPv6 运行值已设为 disable_ipv6=${value}，持久化配置已处理。"
)

disable_ipv6() {
    change_ipv6 1
    show_status
}

enable_ipv6() {
    change_ipv6 0
    warn "仅移除了本脚本的持久化配置；其他网络管理或启动配置仍可能再次关闭 IPv6。"
    show_status
}

###############################################################################
# Check other possible IPv6-related configurations
###############################################################################

check_other_ipv6_configs() {
    echo
    echo "========== 可能影响 IPv6 的其他配置 =========="

    local found=0

    echo
    echo "[1] 检查 sysctl 配置："

    if grep -R --line-number --color=never "disable_ipv6.*=.*1" \
        /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null; then
        found=1
    else
        echo "未发现其他明显的 sysctl IPv6 关闭配置。"
    fi

    echo
    echo "[2] 检查 GRUB 配置："

    if grep -R --line-number --color=never "ipv6.disable=1" \
        /etc/default/grub /boot/grub/grub.cfg 2>/dev/null; then
        found=1
    else
        echo "未发现明显的 GRUB IPv6 禁用参数。"
    fi

    echo
    if [[ "$found" -eq 0 ]]; then
        echo "总结：未发现明显的其他 IPv6 关闭配置。"
    else
        warn "总结：发现了其他可能影响 IPv6 的配置，请人工确认。"
    fi

    echo "============================================="
    echo
}

###############################################################################
# Confirmation helper
###############################################################################

confirm() {
    local prompt="$1"
    local answer

    read -r -p "$prompt [yes/no]: " answer

    case "$answer" in
        yes|YES|y|Y)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

###############################################################################
# Interactive mode
###############################################################################

interactive_menu() {
    show_status
    check_other_ipv6_configs

    if ! ipv6_kernel_available; then
        error "当前系统无法通过 sysctl 管理 IPv6。"
    fi

    if ipv6_runtime_enabled; then
        echo "检测到 IPv6 当前处于开启状态。"
        echo
        if confirm "是否要永久关闭 IPv6？"; then
            disable_ipv6
        else
            log "未执行关闭操作。"
        fi
    else
        echo "检测到 IPv6 当前处于关闭状态。"
        echo
        if confirm "是否要恢复开启 IPv6？"; then
            enable_ipv6
        else
            log "未执行恢复操作。"
        fi
    fi
}

###############################################################################
# Help
###############################################################################

usage() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION}

用法：

  sudo ./${SCRIPT_NAME}
      交互模式：自动检测 IPv6 状态，并询问是否关闭或恢复

  sudo ./${SCRIPT_NAME} status
      查看 IPv6 当前状态

  sudo ./${SCRIPT_NAME} disable
      关闭 IPv6，并写入持久化配置

  sudo ./${SCRIPT_NAME} enable
      恢复开启 IPv6，并删除本脚本创建的持久化配置

  sudo ./${SCRIPT_NAME} check
      检查可能影响 IPv6 的其他配置

  sudo ./${SCRIPT_NAME} help
      显示帮助信息

示例：

  chmod +x ${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} status
  sudo ./${SCRIPT_NAME} disable
  sudo ./${SCRIPT_NAME} enable

说明：

  本脚本使用以下文件管理 IPv6 持久化状态：

    ${SYSCTL_FILE}

  disable 操作会创建或覆盖该文件。
  enable 操作会删除该文件，并尝试恢复 IPv6 运行时状态。

EOF
}

###############################################################################
# Main
###############################################################################

main() {
    need_root

    local action="${1:-interactive}"

    case "$action" in
        interactive)
            interactive_menu
            ;;
        status)
            show_status
            ;;
        disable)
            disable_ipv6
            ;;
        enable)
            enable_ipv6
            ;;
        check)
            check_other_ipv6_configs
            ;;
        -h|--help|help)
            usage
            ;;
        version|--version|-v)
            echo "${SCRIPT_NAME} v${VERSION}"
            ;;
        *)
            usage
            error "未知参数：$action"
            ;;
    esac
}

main "$@"
