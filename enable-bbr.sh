#!/usr/bin/env bash
# enable-bbr.sh — 启用系统内核自带的 BBR，不替换内核。
# Version: 1.1.1 | Updated: 2026-11-05
# 启用（root）：bash enable-bbr.sh；只读检查：bash enable-bbr.sh --check。
# 可选：bash enable-bbr.sh --apply-qdisc（立即切换网卡队列，可能短暂丢包）。
# 配置：/etc/sysctl.d/99-bbr.conf、/etc/modules-load.d/bbr.conf。
# 仅应用自身配置；fq 不可用时只启用 BBR，容器需宿主机允许修改内核参数。
# BBR 对新 TCP 连接生效；已有网卡队列默认不变，mq/noqueue 不强行替换。
# 其他参数见 --help。

set -Eeuo pipefail

# 非 root 下 PATH 可能不包含 sbin 目录
export PATH="${PATH}:/usr/sbin:/sbin"

readonly SCRIPT_VERSION="1.1.1"

readonly SYSCTL_FILE="/etc/sysctl.d/99-bbr.conf"
readonly MODULE_FILE="/etc/modules-load.d/bbr.conf"
readonly OUR_BASENAME="99-bbr.conf"

# sysctl 配置目录，按优先级从高到低（同名文件高优先级目录屏蔽低优先级目录）
readonly -a SYSCTL_DIRS=(
    /etc/sysctl.d
    /run/sysctl.d
    /usr/local/lib/sysctl.d
    /usr/lib/sysctl.d
    /lib/sysctl.d
)

MODE="enable"          # enable | check
APPLY_QDISC=0          # 1 = 立即替换默认路由网卡的根 qdisc
FQ_ENABLED=0           # 本次是否成功启用 fq
TMP_FILES=()           # 需要在退出时清理的临时文件

# ------------------------------------------------------------------------------
# 输出颜色
# ------------------------------------------------------------------------------

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
RESET='\033[0m'

info() {
    printf "${BLUE}[INFO]${RESET} %s\n" "$*"
}

ok() {
    printf "${GREEN}[OK]${RESET} %s\n" "$*"
}

warn() {
    printf "${YELLOW}[WARN]${RESET} %s\n" "$*" >&2
}

die() {
    printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2
    exit 1
}

cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        if [[ -n "${f}" && -e "${f}" ]]; then
            rm -f "${f}"
        fi
    done
    return 0
}
trap cleanup EXIT
trap 'rc=$?; printf "${RED}[ERROR]${RESET} 第 %s 行执行失败（退出码 %s）\n" "${LINENO}" "${rc}" >&2' ERR

# ------------------------------------------------------------------------------
# 帮助 / 参数
# ------------------------------------------------------------------------------

usage() {
    cat <<EOF
BBR Enable Script v${SCRIPT_VERSION}

Usage:
  sudo $0                  启用 BBR（并尽量设置 fq）
  sudo $0 --apply-qdisc    启用 BBR，并立即把默认路由网卡的根 qdisc 换成 fq
  $0 --check               只检查 BBR 状态（只读，无需 root）
  $0 --help                显示帮助
  $0 --version             显示版本
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --check)
                MODE="check"
                ;;
            --apply-qdisc)
                APPLY_QDISC=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                echo "${SCRIPT_VERSION}"
                exit 0
                ;;
            *)
                die "未知参数：$1。使用 --help 查看帮助。"
                ;;
        esac
        shift
    done

    if [[ "${MODE}" == "check" && "${APPLY_QDISC}" -eq 1 ]]; then
        die "--check 是只读模式，不能与 --apply-qdisc 同时使用。"
    fi
}

# ------------------------------------------------------------------------------
# 必须使用 root（仅启用模式）
# ------------------------------------------------------------------------------

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 用户运行，或者执行：sudo $0"
    fi
}

# ------------------------------------------------------------------------------
# 检查必要命令
# ------------------------------------------------------------------------------

check_commands() {
    local cmd

    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            die "缺少必要命令：${cmd}"
        fi
    done
}

# ------------------------------------------------------------------------------
# 读取 /etc/os-release 的某个字段
#
# 在子 shell 中 source，避免污染本脚本的变量（os-release 里有 VERSION 等）。
# ------------------------------------------------------------------------------

os_release_value() {
    local key="$1"
    (
        set +u
        # shellcheck disable=SC1091
        . /etc/os-release >/dev/null 2>&1
        printf '%s' "${!key:-}"
    )
}

# ------------------------------------------------------------------------------
# 检查操作系统
#
# 不会因为识别失败就乱改系统。
# 本脚本主要面向 Debian 12+ / Ubuntu 22.04+
# ------------------------------------------------------------------------------

check_os() {
    local os_id version_id pretty

    if [[ ! -r /etc/os-release ]]; then
        die "无法读取 /etc/os-release，无法确认操作系统。"
    fi

    os_id="$(os_release_value ID)"
    version_id="$(os_release_value VERSION_ID)"
    pretty="$(os_release_value PRETTY_NAME)"

    info "系统：${pretty:-Unknown}"
    info "内核：$(uname -r)"

    case "${os_id}" in
        debian)
            if [[ -z "${version_id}" ]]; then
                warn "未找到 VERSION_ID（可能是 Debian testing/sid），按较新版本处理。"
            elif command -v dpkg >/dev/null 2>&1; then
                if ! dpkg --compare-versions "${version_id}" ge "12"; then
                    die "本脚本要求 Debian 12 或更高版本。"
                fi
            fi
            ;;

        ubuntu)
            if command -v dpkg >/dev/null 2>&1; then
                if ! dpkg --compare-versions "${version_id:-0}" ge "22.04"; then
                    die "本脚本要求 Ubuntu 22.04 或更高版本。"
                fi
            fi
            ;;

        *)
            die "当前系统不是 Debian / Ubuntu。本脚本不会继续修改系统。"
            ;;
    esac

    ok "操作系统检查通过。"
}

# ------------------------------------------------------------------------------
# 检查内核版本（BBR 需要 Linux 4.9+）
# ------------------------------------------------------------------------------

check_kernel() {
    local release major minor

    release="$(uname -r)"
    IFS=. read -r major minor _ <<< "${release%%-*}"

    if [[ ! "${major}" =~ ^[0-9]+$ || ! "${minor}" =~ ^[0-9]+$ ]]; then
        warn "无法解析内核版本 ${release}，跳过版本检查。"
        return 0
    fi

    if ((major < 4 || (major == 4 && minor < 9))); then
        die "内核 ${release} 过旧：BBR 需要 Linux 4.9 或更高版本。"
    fi

    ok "内核版本检查通过：${release}"
}

# ------------------------------------------------------------------------------
# 容器检测（仅警告；是否可写由 check_sysctl_writable 决定）
# ------------------------------------------------------------------------------

detect_container() {
    local container=""

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        container="$(systemd-detect-virt --container 2>/dev/null || true)"
        if [[ -n "${container}" && "${container}" != "none" ]]; then
            warn "检测到容器环境：${container}。容器共享宿主机内核，通常无法在容器内修改 TCP 参数。"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 检查 /proc/sys 是否可写（在做任何修改之前）
# ------------------------------------------------------------------------------

check_sysctl_writable() {
    if [[ ! -w /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        die "无法写入 /proc/sys/net/ipv4/tcp_congestion_control（容器、只读 /proc/sys 或权限限制）。未做任何修改。"
    fi
}

fq_node_writable() {
    [[ -w /proc/sys/net/core/default_qdisc ]]
}

# ------------------------------------------------------------------------------
# 获取当前 BBR 状态
# ------------------------------------------------------------------------------

show_status() {
    echo
    echo "==================== BBR 状态 ===================="

    printf "Kernel:                     "
    uname -r

    printf "Available congestion ctrl:  "
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "UNKNOWN"

    printf "Current congestion ctrl:    "
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "UNKNOWN"

    printf "Default qdisc:              "
    sysctl -n net.core.default_qdisc 2>/dev/null || echo "UNKNOWN"

    echo
    echo "当前网卡 qdisc："

    if command -v tc >/dev/null 2>&1; then
        tc qdisc show || true
    else
        echo "未安装 tc（iproute2），跳过 qdisc 详细检查。"
    fi

    echo
    echo "tcp_bbr 模块："

    if command -v lsmod >/dev/null 2>&1; then
        if grep -q '^tcp_bbr' < <(lsmod); then
            grep '^tcp_bbr' < <(lsmod)
        else
            echo "lsmod 中未发现 tcp_bbr。"
            echo "注意：部分内核也可能将功能直接编译进内核。"
        fi
    else
        echo "系统没有 lsmod，跳过模块显示。"
    fi

    echo "=================================================="
    echo
}

# ------------------------------------------------------------------------------
# 尝试加载 BBR
# ------------------------------------------------------------------------------

load_bbr() {
    local available

    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

    if grep -qw "bbr" <<< "${available}"; then
        ok "当前内核已经支持 BBR。"
        return
    fi

    info "BBR 尚未出现在可用算法中，尝试加载 tcp_bbr 模块..."

    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
    else
        warn "系统中没有 modprobe 命令。"
    fi

    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

    if ! grep -qw "bbr" <<< "${available}"; then
        die "当前内核没有提供可用的 BBR。本脚本不会安装或替换第三方内核。"
    fi

    ok "BBR 内核支持确认完成。"
}

# ------------------------------------------------------------------------------
# 尝试加载 fq 调度器
#
# 加载失败并不立即修改其他系统组件。
# ------------------------------------------------------------------------------

load_fq() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_fq 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 生成配置内容
# 参数 $1：1 = 包含 default_qdisc = fq；0 = 只包含 BBR
# ------------------------------------------------------------------------------

render_sysctl_config() {
    local with_fq="$1"

    cat <<'EOF'
# ==============================================================================
# Linux TCP BBR Configuration
#
# Managed by enable-bbr.sh
#
# BBR: TCP congestion control
# fq : Fair Queue packet scheduler
# ==============================================================================

EOF

    if [[ "${with_fq}" -eq 1 ]]; then
        echo "net.core.default_qdisc = fq"
    else
        echo "# net.core.default_qdisc = fq  (fq unavailable when this file was generated)"
    fi
    echo "net.ipv4.tcp_congestion_control = bbr"
}

render_module_config() {
    cat <<'EOF'
# Linux TCP BBR
tcp_bbr
EOF
}

# ------------------------------------------------------------------------------
# 内容有变化才替换目标文件
# ------------------------------------------------------------------------------

install_if_changed() {
    local src="$1"
    local dst="$2"

    chmod 644 "${src}"

    if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
        rm -f "${src}"
        info "配置无变化，无需重写：${dst}"
        return 0
    fi

    mv -f "${src}" "${dst}"
    chmod 644 "${dst}"
    ok "已写入：${dst}"
}

# ------------------------------------------------------------------------------
# 先应用、后持久化
#
# 1. 配置写入临时文件（隐藏名、非 .conf，不会被 sysctl 误读）
# 2. sysctl -p 只应用这个文件（同时校验语法）
# 3. 成功后才落盘为正式的 99-bbr.conf；失败则不留下任何持久化配置
# 4. fq 无法启用时，退化为只启用 BBR，并不写入 default_qdisc
# ------------------------------------------------------------------------------

apply_and_persist() {
    local with_fq=0
    local tmp_sysctl tmp_module out

    if fq_node_writable; then
        load_fq
        with_fq=1
    else
        warn "/proc/sys/net/core/default_qdisc 不可写，跳过 fq，仅启用 BBR。"
    fi

    install -d -m 755 "$(dirname "${SYSCTL_FILE}")" "$(dirname "${MODULE_FILE}")"

    tmp_sysctl="$(mktemp "$(dirname "${SYSCTL_FILE}")/.99-bbr.XXXXXX")"
    TMP_FILES+=("${tmp_sysctl}")
    render_sysctl_config "${with_fq}" > "${tmp_sysctl}"

    info "应用 BBR 配置（仅应用本脚本的配置文件）..."

    if ! out="$(sysctl -p "${tmp_sysctl}" 2>&1)"; then
        if ((with_fq == 1)); then
            warn "启用 fq 失败，可能缺少 sch_fq：${out}"
            warn "将仅启用 BBR（没有 fq 时 BBR 使用 TCP 自带 pacing，仍可工作）。"
            with_fq=0
            render_sysctl_config 0 > "${tmp_sysctl}"
            out="$(sysctl -p "${tmp_sysctl}" 2>&1)" \
                || die "应用 BBR 失败：${out}。未写入持久化配置。"
        else
            die "应用 BBR 失败：${out}。未写入持久化配置。"
        fi
    fi

    FQ_ENABLED="${with_fq}"
    ok "BBR 配置已应用到当前系统。"

    info "写入持久化配置：${SYSCTL_FILE}"
    install_if_changed "${tmp_sysctl}" "${SYSCTL_FILE}"

    info "写入内核模块自动加载配置：${MODULE_FILE}"
    tmp_module="$(mktemp "$(dirname "${MODULE_FILE}")/.bbr.XXXXXX")"
    TMP_FILES+=("${tmp_module}")
    render_module_config > "${tmp_module}"
    install_if_changed "${tmp_module}" "${MODULE_FILE}"
}

# ------------------------------------------------------------------------------
# 可选：立即把默认路由网卡的根 qdisc 换成 fq（--apply-qdisc）
# ------------------------------------------------------------------------------

apply_qdisc_now() {
    local devs dev root_qdisc

    if ((FQ_ENABLED != 1)); then
        warn "fq 未能启用，跳过 --apply-qdisc。"
        return 0
    fi

    if ! command -v tc >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
        warn "缺少 tc 或 ip（iproute2），跳过 --apply-qdisc。"
        return 0
    fi

    devs="$(ip -o route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }' | sort -u || true)"

    if [[ -z "${devs}" ]]; then
        warn "未找到默认路由网卡，跳过 --apply-qdisc。"
        return 0
    fi

    while IFS= read -r dev; do
        [[ -n "${dev}" ]] || continue

        root_qdisc="$(tc qdisc show dev "${dev}" 2>/dev/null | awk '$4 == "root" { print $2; exit }' || true)"

        case "${root_qdisc}" in
            fq)
                info "${dev}：根 qdisc 已是 fq。"
                ;;
            mq|noqueue|"")
                warn "${dev}：根 qdisc 为 '${root_qdisc:-未知}'（多队列/无队列/无法识别），已跳过。可重启后由 default_qdisc 生效。"
                ;;
            *)
                info "${dev}：根 qdisc ${root_qdisc} -> fq"
                if tc qdisc replace dev "${dev}" root fq; then
                    ok "${dev}：已切换到 fq。"
                else
                    warn "${dev}：切换失败，保持原状。"
                fi
                ;;
        esac
    done <<< "${devs}"
}

# ------------------------------------------------------------------------------
# 检查是否存在其他可能冲突的配置
#
# 只关心“加载顺序排在 99-bbr.conf 之后”的配置，它们会在重启后覆盖我们。
# 排在前面的会被我们覆盖，不构成问题（--check 模式下仅作信息展示）。
# 这里只提醒，不自动删除。
# ------------------------------------------------------------------------------

sorts_after_ours() {
    local base="$1"
    [[ "${base}" != "${OUR_BASENAME}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "${OUR_BASENAME}" "${base}" | LC_ALL=C sort | tail -n1)" == "${base}" ]]
}

# 输出格式：early|path:line:content 或 late|path:line:content
collect_definitions() {
    local -A seen=()
    local -A real=()
    local pattern='^[[:space:]]*-?[[:space:]]*net[./](ipv4[./]tcp_congestion_control|core[./]default_qdisc)[[:space:]]*='
    local our_real dir f base rp label matches line

    our_real="$(readlink -f "${SYSCTL_FILE}" 2>/dev/null || echo "${SYSCTL_FILE}")"

    for dir in "${SYSCTL_DIRS[@]}"; do
        [[ -d "${dir}" ]] || continue
        for f in "${dir}"/*.conf; do
            [[ -e "${f}" ]] || continue
            base="${f##*/}"

            # 同名文件被高优先级目录屏蔽
            [[ -z "${seen[${base}]:-}" ]] || continue
            seen["${base}"]=1

            rp="$(readlink -f "${f}" 2>/dev/null || echo "${f}")"
            [[ "${rp}" != "${our_real}" ]] || continue
            [[ -z "${real[${rp}]:-}" ]] || continue
            real["${rp}"]=1

            matches="$(grep -HnE "${pattern}" "${rp}" 2>/dev/null || true)"
            [[ -n "${matches}" ]] || continue

            if sorts_after_ours "${base}"; then
                label="late"
            else
                label="early"
            fi

            while IFS= read -r line; do
                printf '%s|%s\n' "${label}" "${line}"
            done <<< "${matches}"
        done
    done

    # /etc/sysctl.conf 在 Debian/Ubuntu 上最后读取（通常经 99-sysctl.conf 软链）
    if [[ -f /etc/sysctl.conf ]]; then
        rp="$(readlink -f /etc/sysctl.conf)"
        if [[ -z "${real[${rp}]:-}" ]]; then
            matches="$(grep -HnE "${pattern}" /etc/sysctl.conf 2>/dev/null || true)"
            if [[ -n "${matches}" ]]; then
                while IFS= read -r line; do
                    printf 'late|%s\n' "${line}"
                done <<< "${matches}"
            fi
        fi
    fi
}

report_conflicts() {
    local verbose="$1"      # 1 = 同时展示加载顺序在前的配置（--check）
    local defs late early

    defs="$(collect_definitions)"
    late="$(grep '^late|' <<< "${defs}" || true)"
    early="$(grep '^early|' <<< "${defs}" || true)"

    if [[ -n "${late}" ]]; then
        warn "发现加载顺序排在 ${OUR_BASENAME} 之后的配置，重启后会覆盖 BBR/qdisc 设置："
        echo
        sed 's/^late|/  /' <<< "${late}"
        echo
        warn "本脚本不会自动删除这些配置，请检查上述文件。"
    else
        ok "未发现会在 ${OUR_BASENAME} 之后覆盖本配置的 sysctl 设置。"
    fi

    if [[ "${verbose}" -eq 1 && -n "${early}" ]]; then
        info "以下配置加载顺序在 ${OUR_BASENAME} 之前，会被本配置覆盖（仅供参考）："
        sed 's/^early|/  /' <<< "${early}"
    fi
}

# ------------------------------------------------------------------------------
# 最终验证
# ------------------------------------------------------------------------------

verify() {
    local congestion
    local qdisc
    local available

    available="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
    congestion="$(sysctl -n net.ipv4.tcp_congestion_control)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"

    if ! grep -qw "bbr" <<< "${available}"; then
        die "验证失败：BBR 不在可用拥塞控制算法中。"
    fi

    if [[ "${congestion}" != "bbr" ]]; then
        die "验证失败：当前 TCP congestion control 不是 bbr。"
    fi

    if [[ ! -f "${SYSCTL_FILE}" ]] || ! grep -q '^net\.ipv4\.tcp_congestion_control = bbr' "${SYSCTL_FILE}"; then
        die "验证失败：持久化配置 ${SYSCTL_FILE} 不存在或内容不正确。"
    fi

    if [[ "${qdisc}" != "fq" ]]; then
        if ((FQ_ENABLED == 1)); then
            warn "default_qdisc 当前不是 fq，而是：${qdisc}"
        else
            warn "default_qdisc = ${qdisc}（fq 不可用或未启用）；BBR 仍可使用 TCP 自带 pacing 工作。"
        fi
    else
        ok "默认 qdisc = fq"
    fi

    ok "TCP congestion control = bbr"

    echo
    printf "${GREEN}"
    echo "=================================================="
    echo " BBR 已成功启用"
    echo "=================================================="
    printf "${RESET}"

    echo
    echo "当前配置："
    echo "  TCP congestion control : ${congestion}"
    echo "  Default qdisc          : ${qdisc}"
    echo "  Kernel                 : $(uname -r)"
    echo
}

# ------------------------------------------------------------------------------
# 主程序
# ------------------------------------------------------------------------------

main() {
    parse_args "$@"

    echo
    echo "BBR Enable Script v${SCRIPT_VERSION}"
    echo

    if [[ "${MODE}" == "check" ]]; then
        check_commands sysctl uname grep awk
        check_os
        show_status
        report_conflicts 1
        exit 0
    fi

    require_root
    check_commands sysctl uname grep awk cmp mktemp readlink sort
    check_os
    check_kernel
    detect_container

    show_status

    check_sysctl_writable
    load_bbr
    apply_and_persist

    if ((APPLY_QDISC == 1)); then
        apply_qdisc_now
    fi

    report_conflicts 0
    verify

    show_status

    echo "完成。"
    echo
    echo "BBR 已对新的 TCP 连接生效，无需重启。"
    echo "如果 tc qdisc show 中网卡当前还不是 fq，这不影响 BBR 工作；"
    echo "如需立即切换，可执行：sudo $0 --apply-qdisc"
    echo "或在合适的维护时间重启服务器，然后再次检查："
    echo
    echo "  $0 --check"
    echo
}

main "$@"
