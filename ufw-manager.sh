#!/usr/bin/env bash
# ufw-manager.sh — 独立管理主机防火墙，保留 SSH 锁死保护。
# Version: 1.5.1 | Updated: 2026-11-05
# 用法（root）：bash ufw-manager.sh check；更多命令见 --help。
# 新机初始化：bash ufw-manager.sh init（确认后重建，默认放行 SSH 和 443/tcp）。
# init --yes 重建规则，失败恢复原配置及启用状态；完整备份保存在 /var/backups/ufw-manager。
# restrict 先增加来源规则再移除公网放行；读取、删除失败或仍有公网覆盖时停止。
# Docker 发布端口不应仅依赖 UFW 保护；check 会提示相关情况。

set -Eeuo pipefail

# 固定英文输出，保证解析稳定；补充 sbin 路径。
export LC_ALL=C
export PATH="${PATH}:/usr/sbin:/sbin"

readonly SCRIPT_VERSION="1.5.1"
readonly DEFAULT_TCP_PORT="443"
readonly DEFAULT_PROTOCOL="tcp"
readonly DEFAULT_SSH_PORT="22"
readonly UFW_DEFAULTS_FILE="/etc/default/ufw"
readonly UFW_CONFIG_DIR="/etc/ufw"
readonly UFW_BACKUP_DIR="/var/backups/ufw-manager"

readonly SCRIPT_NAME="$(basename "$0")"

# 常见高风险端口：
# 80: Web 明文入口
# 2095/2096: 常见面板端口
# 3000/5000/8000/8080/8443/9000: 常见开发服务或管理面板
# 3306/5432/6379/9200/27017: 常见数据库与中间件
readonly -a HIGH_RISK_PORTS=(80 2095 2096 3000 5000 8000 8080 8443 9000 3306 5432 6379 9200 27017)

# 子命令参数解析结果
POS=()
OPT_YES=0
OPT_COMMENT=""

# SSH 端口探测结果（缓存）
SSH_PORTS=()
SSH_PORT_SOURCES=""
SSH_PORTS_DETECTED=0

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

err() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  err "$*"
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  sudo ./ufw-manager.sh init --yes
      初始化 UFW 基础规则：
      - 破坏性操作，会重置现有 UFW 规则（ufw 会自动备份原规则文件）
      - 必须显式传入 --yes
      - 默认拒绝所有入站、允许所有出站
      - 自动放行探测到的所有 SSH 端口（含当前会话端口）
      - 自动放行 443/tcp

  sudo ./ufw-manager.sh status
      查看当前 UFW 状态与规则（未启用时列出已添加的规则）

  sudo ./ufw-manager.sh check
      检查 UFW 状态、默认策略、IPv6、SSH 端口、443/tcp、高风险公网开放规则、Docker 发布端口

  sudo ./ufw-manager.sh add <port> [tcp|udp] [--comment TEXT]
      添加端口规则
      示例：
        sudo ./ufw-manager.sh add 80
        sudo ./ufw-manager.sh add 51820 udp --comment "WireGuard"

  sudo ./ufw-manager.sh add-from <source_ip_or_cidr> <port> [tcp|udp] [--comment TEXT]
      添加来源限制规则
      示例：
        sudo ./ufw-manager.sh add-from 96.44.175.11 2222
        sudo ./ufw-manager.sh add-from 10.0.0.0/24 51820 udp

  sudo ./ufw-manager.sh restrict <source_ip_or_cidr> <port> [tcp|udp] [--comment TEXT] [--yes]
      将端口限制为仅允许指定来源 IP 或 CIDR 访问
      - 先添加来源规则，再删除该端口的公网规则（添加失败则不删除任何规则）
      - 目标为 SSH 端口时会校验当前 SSH 来源 IP，不在范围内需 --yes 强制
      - 完成后列出仍覆盖该端口的公网规则
      示例：
        sudo ./ufw-manager.sh restrict 96.44.175.11 2222
        sudo ./ufw-manager.sh restrict 10.0.0.0/24 51820 udp

  sudo ./ufw-manager.sh del <port> [tcp|udp] [--yes]
      删除端口规则（SSH 端口需 --yes）
      示例：
        sudo ./ufw-manager.sh del 80
        sudo ./ufw-manager.sh del 51820 udp

  sudo ./ufw-manager.sh del-from <source_ip_or_cidr> <port> [tcp|udp] [--yes]
      删除来源限制规则（SSH 端口需 --yes）
      示例：
        sudo ./ufw-manager.sh del-from 96.44.175.11 2222 --yes
        sudo ./ufw-manager.sh del-from 10.0.0.0/24 51820 udp

  sudo ./ufw-manager.sh version
      查看脚本版本

说明：
  - 协议默认是 tcp；支持端口范围，例如：10000:20000
  - init 是破坏性操作，会执行 ufw --force reset，必须显式传入 --yes
  - restrict 适合把已经对公网开放的端口收紧到指定来源
  - check 适合日常巡检服务器防火墙状态
  - Docker 发布的端口不受 UFW 约束，请结合 check 输出确认
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 权限运行，例如：sudo $SCRIPT_NAME ..."
  fi
}

require_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    die "未检测到 ufw，请先安装：apt update && apt install -y ufw"
  fi
}

# ------------------------------------------------------------------------------
# 参数解析与校验
# ------------------------------------------------------------------------------

parse_cmd_args() {
  POS=()
  while (($# > 0)); do
    case "$1" in
      -y|--yes)
        OPT_YES=1
        ;;
      --comment)
        [[ $# -ge 2 ]] || die "--comment 需要参数"
        OPT_COMMENT="$2"
        shift
        ;;
      --comment=*)
        OPT_COMMENT="${1#*=}"
        ;;
      --)
        shift
        POS+=("$@")
        break
        ;;
      -*)
        die "未知选项：$1。使用 --help 查看帮助"
        ;;
      *)
        POS+=("$1")
        ;;
    esac
    shift
  done

  if [[ "$OPT_COMMENT" == *$'\n'* ]]; then
    die "--comment 不能包含换行"
  fi
}

validate_protocol() {
  local proto="${1:-tcp}"
  case "$proto" in
    tcp|udp) ;;
    *)
      die "无效协议：$proto。仅支持 tcp 或 udp"
      ;;
  esac
}

validate_port() {
  local port="$1"

  # 支持单端口，例如 22
  # 也支持端口范围，例如 10000:20000
  if [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
    (( port >= 1 && port <= 65535 )) || die "端口超出范围：$port"
    return 0
  fi

  if [[ "$port" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
    local start="${BASH_REMATCH[1]}"
    local end="${BASH_REMATCH[2]}"
    (( start >= 1 && start <= 65535 )) || die "起始端口超出范围：$start"
    (( end >= 1 && end <= 65535 )) || die "结束端口超出范围：$end"
    (( start <= end )) || die "端口范围不合法：$port"
    return 0
  fi

  die "无效端口格式：$port"
}

validate_source() {
  local source="$1"

  # 防止空值、选项注入和包含空白字符；具体 IP/CIDR 合法性由 UFW 校验。
  [[ -n "$source" ]] || die "来源 IP 或 CIDR 不能为空"
  [[ "$source" != -* ]] || die "无效来源 IP 或 CIDR：$source"
  [[ "$source" != *[[:space:]]* ]] || die "无效来源 IP 或 CIDR：$source"
}

# ------------------------------------------------------------------------------
# ufw 命令封装
# ------------------------------------------------------------------------------

ufw_is_active() {
  ufw status 2>/dev/null | grep -qi '^status: active'
}

# 执行一条规则命令；ERROR 或非零退出码视为失败并终止。
ufw_run() {
  local out=""
  local rc=0
  out="$(ufw "$@" 2>&1)" || rc=$?
  if (( rc != 0 )) || grep -q '^ERROR' <<< "$out"; then
    die "执行失败：ufw $*：${out}"
  fi
  if grep -q '^Skipping' <<< "$out"; then
    log "规则已存在，跳过：ufw $*"
  fi
}

# 删除一条规则。
# 返回：0 = 已删除；2 = 规则不存在；1 = 其他失败。
# 注意：ufw 删除不存在的规则时退出码也是 0，只能通过输出判断。
ufw_delete() {
  local out=""
  local rc=0
  out="$(ufw --force delete "$@" 2>&1)" || rc=$?
  if grep -q 'Could not delete non-existent rule' <<< "$out"; then
    return 2
  fi
  if (( rc != 0 )) || grep -q '^ERROR' <<< "$out"; then
    warn "删除失败：ufw delete $*：${out}"
    return 1
  fi
  return 0
}

comment_args() {
  if [[ -n "$OPT_COMMENT" ]]; then
    printf '%s\0%s\0' "comment" "$OPT_COMMENT"
  fi
}

# 展示规则：启用时显示带编号的运行规则；未启用时显示已添加的规则。
show_rules() {
  if ufw_is_active; then
    ufw status numbered
  else
    warn "UFW 当前未启用，以下为已添加但未生效的规则："
    ufw show added
  fi
}

# ------------------------------------------------------------------------------
# 规则解析（基于 ufw show added）
#
# 输出每行：action|dir|src|dport|proto|app|raw
#   action: allow / limit / deny / reject
#   dir   : in / out
#   src   : any 或来源地址
#   dport : 目标端口规格（22、1000:2000、80,443、any）；应用规则为空
#   proto : tcp / udp / any
#   app   : 应用配置名（如 OpenSSH），非应用规则为空
#   raw   : 原始规则（去掉前缀 "ufw "）
# route（转发）规则不在本脚本管理范围，忽略。
# ------------------------------------------------------------------------------

list_added_rules() {
  ufw show added 2>/dev/null | awk '
    /^ufw / {
      raw = substr($0, 5)
      line = raw
      ci = index(line, " comment ")
      if (ci > 0) line = substr(line, 1, ci - 1)
      n = split(line, t, /[ \t]+/)
      i = 1
      if (t[i] == "route") next
      action = t[i]; i++
      if (action != "allow" && action != "deny" && action != "reject" && action != "limit") next
      dir = "in"
      if (t[i] == "in" || t[i] == "out") { dir = t[i]; i++ }
      if (t[i] == "on") { i += 2 }
      src = "any"; dport = ""; proto = "any"; app = ""; ctx = ""; full = 0
      for (j = i; j <= n; j++) if (t[j] == "from" || t[j] == "to") full = 1
      if (!full) {
        rest = ""
        for (j = i; j <= n; j++) rest = rest (rest == "" ? "" : " ") t[j]
        if (rest ~ /^[0-9][0-9:,]*(\/(tcp|udp))?$/) {
          k = index(rest, "/")
          if (k > 0) { dport = substr(rest, 1, k - 1); proto = substr(rest, k + 1) } else { dport = rest }
        } else {
          app = rest
          gsub(/^\047|\047$/, "", app)
          gsub(/^"|"$/, "", app)
        }
      } else {
        for (j = i; j <= n; j++) {
          if (t[j] == "from")  { ctx = "from"; src = t[j + 1]; j++; continue }
          if (t[j] == "to")    { ctx = "to"; j++; continue }
          if (t[j] == "port")  { if (ctx == "to") dport = t[j + 1]; j++; continue }
          if (t[j] == "proto") { proto = t[j + 1]; j++; continue }
          if (t[j] == "app")   { if (ctx == "to") app = t[j + 1]; j++; continue }
        }
        gsub(/^\047|\047$/, "", app)
        if (dport == "" && app == "") dport = "any"
      }
      printf "%s|%s|%s|%s|%s|%s|%s\n", action, dir, src, dport, proto, app, raw
    }'
}

is_any_source() {
  case "$1" in
    any|""|0.0.0.0/0|::/0) return 0 ;;
  esac
  return 1
}

# spec_overlaps SPEC TARGET
#   SPEC  : any | 22 | 1000:2000 | 80,443 | 80,1000:2000
#   TARGET: 22 | 1000:2000
spec_overlaps() {
  local spec="$1"
  local target="$2"
  local ts te item rs re
  local -a items=()

  [[ "$spec" != "any" ]] || return 0
  [[ -n "$spec" ]] || return 1

  ts="${target%%:*}"
  te="${target##*:}"
  IFS=',' read -r -a items <<< "$spec"
  for item in "${items[@]}"; do
    rs="${item%%:*}"
    re="${item##*:}"
    [[ "$rs" =~ ^[0-9]+$ && "$re" =~ ^[0-9]+$ ]] || continue
    if (( rs <= te && ts <= re )); then
      return 0
    fi
  done
  return 1
}

proto_matches() {
  [[ "$1" == "any" || "$2" == "any" || "$1" == "$2" ]]
}

# 输出应用配置的端口规格，每行 "spec/proto" 或 "spec"
app_port_specs() {
  ufw app info "$1" 2>/dev/null | awk '
    /^Ports?:/ { f = 1; next }
    f && NF { gsub(/^[ \t]+|[ \t]+$/, ""); print }
  '
}

# matching_allow_rules TARGET PROTO SCOPE
#   SCOPE: public = 只要来源为任意的规则；all = 任意来源
# 输出：action|src|raw（覆盖目标端口与协议的 allow/limit 入站规则）
matching_allow_rules() {
  local target="$1"
  local want_proto="$2"
  local scope="$3"
  local action dir src dport proto app raw line spec p
  local rules app_specs

  # 先确认读取成功，避免把读取失败当成没有规则。
  rules="$(list_added_rules)" || return 1

  while IFS='|' read -r action dir src dport proto app raw; do
    [[ "$action" == "allow" || "$action" == "limit" ]] || continue
    [[ "$dir" == "in" ]] || continue
    if [[ "$scope" == "public" ]] && ! is_any_source "$src"; then
      continue
    fi

    if [[ -n "$app" ]]; then
      app_specs="$(app_port_specs "$app")" || return 1
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        spec="${line%%/*}"
        p="any"
        if [[ "$line" == */* ]]; then
          p="${line##*/}"
        fi
        if spec_overlaps "$spec" "$target" && proto_matches "$p" "$want_proto"; then
          printf '%s|%s|%s\n' "$action" "$src" "$raw"
          break
        fi
      done <<< "$app_specs"
    elif spec_overlaps "$dport" "$target" && proto_matches "$proto" "$want_proto"; then
      printf '%s|%s|%s\n' "$action" "$src" "$raw"
    fi
  done <<< "$rules"
}

# ------------------------------------------------------------------------------
# SSH 端口探测与锁死保护
# ------------------------------------------------------------------------------

# 当前 SSH 连接信息："client_ip client_port server_ip server_port"
# sudo 默认会清理 SSH_CONNECTION，因此沿父进程向上查找。
current_ssh_connection() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    printf '%s\n' "$SSH_CONNECTION"
    return 0
  fi

  local pid="$PPID"
  local val=""
  local guard=0
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 && guard < 32 )); do
    val="$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n1 || true)"
    if [[ -n "$val" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
    pid="$(awk '/^PPid:/ { print $2 }' "/proc/${pid}/status" 2>/dev/null || echo 0)"
    guard=$((guard + 1))
  done
  return 1
}

detect_ssh_ports() {
  (( SSH_PORTS_DETECTED == 0 )) || return 0

  local -a found=()
  local -a sources=()
  local sshd_bin="" out="" listen="" conn="" p=""
  local before=0

  # 1) sshd -T：读取最终生效配置（含 sshd_config.d）
  sshd_bin="$(command -v sshd 2>/dev/null || true)"
  if [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]]; then
    sshd_bin="/usr/sbin/sshd"
  fi
  if [[ -n "$sshd_bin" ]]; then
    # Ubuntu 24.04 使用 ssh.socket 按需启动，ssh.service 未运行时 /run/sshd 不存在，
    # 会导致 sshd -T 报 "Missing privilege separation directory"。
    [[ -d /run/sshd ]] || install -d -m 0755 /run/sshd
    if out="$("$sshd_bin" -T 2>/dev/null)"; then
      while read -r p; do
        found+=("$p")
      done < <(awk '$1 == "port" { print $2 }' <<< "$out")
      sources+=("sshd -T")
    fi
  fi

  # 2) 回退：解析主配置与 drop-in（Port 可多次出现，全部生效）
  if (( ${#found[@]} == 0 )); then
    local -a files=()
    [[ -r /etc/ssh/sshd_config ]] && files+=(/etc/ssh/sshd_config)
    if compgen -G "/etc/ssh/sshd_config.d/*.conf" >/dev/null; then
      files+=(/etc/ssh/sshd_config.d/*.conf)
    fi
    if (( ${#files[@]} > 0 )); then
      while read -r p; do
        found+=("$p")
      done < <(awk '
        /^[[:space:]]*#/ { next }
        tolower($1) == "port" { print $2 }
      ' "${files[@]}" 2>/dev/null || true)
      (( ${#found[@]} == 0 )) || sources+=("sshd_config(.d)")
    fi
  fi

  # 3) ssh.socket 实际监听端口（Ubuntu 24.04 默认 socket activation）
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      listen="$(systemctl show ssh.socket -p Listen --value 2>/dev/null || true)"
      before=${#found[@]}
      while read -r p; do
        [[ -n "$p" ]] && found+=("$p")
      done < <(grep -oE ':[0-9]+ \(Stream\)' <<< "$listen" | grep -oE '[0-9]+' || true)
      (( ${#found[@]} == before )) || sources+=("ssh.socket")
    fi
  fi

  # 4) 当前 SSH 会话使用的端口
  if conn="$(current_ssh_connection)"; then
    p="$(awk '{ print $4 }' <<< "$conn")"
    if [[ -n "$p" ]]; then
      found+=("$p")
      sources+=("当前会话")
    fi
  fi

  if (( ${#found[@]} == 0 )); then
    found=("$DEFAULT_SSH_PORT")
    sources+=("默认值")
  fi

  mapfile -t SSH_PORTS < <(printf '%s\n' "${found[@]}" | grep -E '^[0-9]{1,5}$' | awk '$1 >= 1 && $1 <= 65535' | sort -n -u)
  if (( ${#SSH_PORTS[@]} == 0 )); then
    SSH_PORTS=("$DEFAULT_SSH_PORT")
  fi
  SSH_PORT_SOURCES="$(printf "%s, " "${sources[@]}")"
  SSH_PORT_SOURCES="${SSH_PORT_SOURCES%, }"
  SSH_PORTS_DETECTED=1
}

# 目标端口规格是否覆盖任一 SSH 端口
targets_ssh_port() {
  local port="$1"
  local proto="$2"
  local p

  [[ "$proto" == "tcp" ]] || return 1
  detect_ssh_ports
  for p in "${SSH_PORTS[@]}"; do
    if spec_overlaps "$port" "$p"; then
      return 0
    fi
  done
  return 1
}

# ip_in_source IP SOURCE：0 = 属于；1 = 不属于；2 = 无法判断
ip_in_source() {
  command -v python3 >/dev/null 2>&1 || return 2
  python3 - "$1" "$2" <<'PY'
import ipaddress
import sys
try:
    ip = ipaddress.ip_address(sys.argv[1].split('%')[0])
    net = ipaddress.ip_network(sys.argv[2], strict=False)
except ValueError:
    sys.exit(2)
if ip.version == 6 and ip.ipv4_mapped is not None and net.version == 4:
    ip = ip.ipv4_mapped
if ip.version != net.version:
    sys.exit(1)
sys.exit(0 if ip in net else 1)
PY
}

# restrict 前的锁死保护：目标为 SSH 端口时，校验当前 SSH 来源是否在允许范围内。
guard_restrict_ssh() {
  local source="$1"
  local port="$2"
  local proto="$3"
  local conn="" client="" rc=0

  targets_ssh_port "$port" "$proto" || return 0

  warn "${port}/${proto} 涉及 SSH 端口（${SSH_PORTS[*]}）。"

  if ! conn="$(current_ssh_connection)"; then
    if (( OPT_YES == 1 )); then
      warn "无法确定当前 SSH 来源 IP（可能不是通过 SSH 登录）；因 --yes 继续执行。"
      return 0
    fi
    die "无法确定当前 SSH 来源 IP，无法确认收紧后仍能登录。确认无误请追加 --yes。"
  fi

  client="${conn%% *}"
  ip_in_source "$client" "$source" || rc=$?

  case "$rc" in
    0)
      log "当前 SSH 来源 ${client} 在 ${source} 范围内，收紧后仍可登录。"
      ;;
    1)
      if (( OPT_YES == 1 )); then
        warn "当前 SSH 来源 ${client} 不在 ${source} 范围内；因 --yes 继续执行，断开后将无法从当前位置重新登录！"
      else
        die "当前 SSH 来源 ${client} 不在 ${source} 范围内，执行后将无法从当前位置重新登录。确认无误请追加 --yes。"
      fi
      ;;
    *)
      if (( OPT_YES == 1 )); then
        warn "无法校验 ${client} 是否属于 ${source}（缺少 python3 或格式无法解析）；因 --yes 继续执行。"
      else
        die "无法校验 ${client} 是否属于 ${source}（缺少 python3 或格式无法解析）。确认无误请追加 --yes。"
      fi
      ;;
  esac
}

# del / del-from 的锁死保护：涉及 SSH 端口必须 --yes。
guard_delete_ssh() {
  local port="$1"
  local proto="$2"

  targets_ssh_port "$port" "$proto" || return 0

  if (( OPT_YES == 1 )); then
    warn "正在删除 SSH 端口相关规则（${SSH_PORTS[*]}），因 --yes 继续执行。"
    return 0
  fi
  die "${port}/${proto} 涉及 SSH 端口（${SSH_PORTS[*]}），删除可能导致无法登录。确认无误请追加 --yes。"
}

show_version() {
  printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
}

# ------------------------------------------------------------------------------
# 子命令
# ------------------------------------------------------------------------------

# 初始化 UFW：
# - 必须显式传入 --yes
# - ufw reset 会关闭防火墙并自动备份原规则文件
# - 默认拒绝所有入站、允许所有出站
# - 放行探测到的所有 SSH 端口与 443/tcp，然后启用
init_ufw() (
  (( OPT_YES == 1 )) || die "init 会重置现有规则，请显式传入 --yes。"
  detect_ssh_ports
  [[ -d "$UFW_CONFIG_DIR" && -f "$UFW_DEFAULTS_FILE" ]] || die "UFW 配置不完整，拒绝重置。"
  for file in "$UFW_CONFIG_DIR" "$UFW_DEFAULTS_FILE" \
      "$UFW_CONFIG_DIR"/{before.rules,after.rules,user.rules,before6.rules,after6.rules,user6.rules,ufw.conf,sysctl.conf}; do
    [[ ! -L "$file" ]] || die "无法安全备份符号链接，拒绝重置：$file"
  done
  original_status="$(ufw status)"
  case "$original_status" in
    *'Status: active'*) original_active=1 ;;
    *'Status: inactive'*) original_active=0 ;;
    *) die "无法识别原防火墙状态，拒绝重置。" ;;
  esac
  install -d -m 700 "$UFW_BACKUP_DIR"
  backup_dir="$(mktemp -d "$UFW_BACKUP_DIR/backup.XXXXXX")"
  cp -a "$UFW_CONFIG_DIR" "$backup_dir/config"
  cp -p "$UFW_DEFAULTS_FILE" "$backup_dir/defaults"
  committed=0 started=0

  restore_ufw() {
    local rc=$? failed=0 output=""
    trap - EXIT
    if [[ "$committed" == 0 && "$started" == 1 ]]; then
      warn "重建失败，正在恢复原 UFW 配置和启用状态。"
      cp -a "$backup_dir/config/." "$UFW_CONFIG_DIR/" || failed=1
      cp -p "$backup_dir/defaults" "$UFW_DEFAULTS_FILE" || failed=1
      if [[ "$failed" == 0 ]]; then
        if [[ "$original_active" == 1 ]]; then
          output="$(ufw --force enable 2>&1 && ufw reload 2>&1)" || failed=1
          ufw_is_active || failed=1
        else
          output="$(ufw --force disable 2>&1)" || failed=1
          if ufw_is_active; then failed=1; fi
        fi
        if grep -q '^ERROR' <<< "$output"; then failed=1; fi
      fi
      if [[ "$failed" == 1 ]]; then
        warn "自动恢复未全部完成，请立即检查防火墙。${output}"
      else
        warn "原 UFW 配置和启用状态已恢复。"
      fi
    fi
    log "完整备份保留在：$backup_dir"
    exit "$rc"
  }
  trap restore_ufw EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  log "将放行 SSH 端口：${SSH_PORTS[*]}，以及 ${DEFAULT_TCP_PORT}/tcp。"
  started=1
  ufw_run --force reset
  ufw_run default deny incoming
  ufw_run default allow outgoing
  for ssh_port in "${SSH_PORTS[@]}"; do
    ufw_run allow "${ssh_port}/tcp"
  done
  ufw_run allow "${DEFAULT_TCP_PORT}/${DEFAULT_PROTOCOL}"
  ufw_run --force enable
  ufw_is_active || die "UFW 启用后状态检查失败。"
  committed=1
  log "初始化完成，当前规则如下："
  ufw status numbered
)

# 展示当前 UFW 状态与规则明细。
show_status() {
  if ufw_is_active; then
    log "当前 UFW 状态："
    ufw status verbose
    echo
    log "当前 UFW 规则（带编号）："
    ufw status numbered
  else
    warn "UFW 当前未启用（inactive），规则不会生效。"
    echo
    log "已添加的规则："
    ufw show added
  fi
}

# 添加一条允许规则。
add_rule() {
  local port="$1"
  local proto="${2:-tcp}"
  local -a extra=()

  validate_port "$port"
  validate_protocol "$proto"
  mapfile -d '' -t extra < <(comment_args)

  log "添加规则：allow ${port}/${proto}"
  ufw_run allow "${port}/${proto}" "${extra[@]}"

  log "添加完成，当前规则如下："
  show_rules
}

# 列出与某端口相关的现有规则（用于删除失败时提示）
hint_related_rules() {
  local port="$1"
  local proto="$2"
  local related=""

  related="$(matching_allow_rules "$port" "$proto" all | cut -d'|' -f3-)" \
    || die "无法读取防火墙规则，请检查 UFW。"
  if [[ -n "$related" ]]; then
    warn "当前与 ${port}/${proto} 相关的规则如下，可能需要用对应形式删除："
    sed 's/^/  ufw /' <<< "$related" >&2
  fi
}

# 删除一条允许规则。
# 删除不存在的规则时不中断，而是给出警告，便于重复执行。
delete_rule() {
  local port="$1"
  local proto="${2:-tcp}"
  local rc=0

  validate_port "$port"
  validate_protocol "$proto"
  guard_delete_ssh "$port" "$proto"

  log "删除规则：allow ${port}/${proto}"
  ufw_delete allow "${port}/${proto}" || rc=$?

  case "$rc" in
    0) log "删除完成，当前规则如下：" ;;
    2)
      warn "规则不存在或已被删除：allow ${port}/${proto}"
      hint_related_rules "$port" "$proto"
      log "当前规则如下："
      ;;
    *) die "删除失败：allow ${port}/${proto}" ;;
  esac

  show_rules
}

# 添加一条允许规则，限定来源 IP 或 CIDR。
add_rule_from() {
  local source="$1"
  local port="$2"
  local proto="${3:-tcp}"
  local -a extra=()

  validate_source "$source"
  validate_port "$port"
  validate_protocol "$proto"
  mapfile -d '' -t extra < <(comment_args)

  log "添加规则：allow from ${source} to any port ${port}/${proto}"
  ufw_run allow from "$source" to any port "$port" proto "$proto" "${extra[@]}"

  log "添加完成，当前规则如下："
  show_rules
}

# 删除一条允许规则，限定来源 IP 或 CIDR。
# 删除不存在的规则时不中断，而是给出警告，便于重复执行。
delete_rule_from() {
  local source="$1"
  local port="$2"
  local proto="${3:-tcp}"
  local rc=0

  validate_source "$source"
  validate_port "$port"
  validate_protocol "$proto"
  guard_delete_ssh "$port" "$proto"

  log "删除规则：allow from ${source} to any port ${port}/${proto}"
  ufw_delete allow from "$source" to any port "$port" proto "$proto" || rc=$?

  case "$rc" in
    0) log "删除完成，当前规则如下：" ;;
    2)
      warn "规则不存在或已被删除：allow from ${source} to any port ${port}/${proto}"
      hint_related_rules "$port" "$proto"
      log "当前规则如下："
      ;;
    *) die "删除失败：allow from ${source} to any port ${port}/${proto}" ;;
  esac

  show_rules
}

# 检查指定端口是否仍存在面向任意来源的放行规则（含范围/列表/应用/全端口/LIMIT）。
check_public_allow_for_port() {
  local port="$1"
  local proto="$2"
  local matched=""

  matched="$(matching_allow_rules "$port" "$proto" public | cut -d'|' -f3-)" \
    || die "无法读取防火墙规则，无法确认收紧结果。"

  if [[ -n "$matched" ]]; then
    warn "检测到 ${port}/${proto} 仍被以下面向任意来源的规则覆盖，请手动确认（脚本不会自动删除这类规则）："
    sed 's/^/  ufw /' <<< "$matched" >&2
    return 1
  fi

  log "未检测到 ${port}/${proto} 面向任意来源的放行规则"
}

# 删除与目标端口精确对应的公网规则。
# 不带协议的规则（如 allow 2222）同时覆盖 tcp/udp：删除后为另一协议补回，保持其原有开放状态。
remove_exact_public_rules() {
  local port="$1"
  local proto="$2"
  local other="udp"
  local act=""
  local rc=0

  [[ "$proto" == "tcp" ]] || other="tcp"

  for act in allow limit; do
    rc=0
    ufw_delete "$act" "${port}/${proto}" || rc=$?
    if (( rc == 0 )); then
      log "已删除公网规则：${act} ${port}/${proto}"
    elif (( rc != 2 )); then
      die "删除公网规则失败：${act} ${port}/${proto}；收紧未完成。"
    fi

    # 端口范围在 ufw 中必须带协议，只有单端口才可能存在不带协议的规则
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      rc=0
      ufw_delete "$act" "$port" || rc=$?
      if (( rc == 0 )); then
        log "已删除公网规则：${act} ${port}（同时覆盖 tcp/udp）"
        ufw_run "$act" "${port}/${other}"
        log "为保持原状，已补回另一协议：${act} ${port}/${other}"
      elif (( rc != 2 )); then
        die "删除公网规则失败：${act} ${port}；收紧未完成。"
      fi
    fi
  done
}

# 将端口收紧为仅允许指定来源 IP 或 CIDR 访问。
# 顺序：锁死保护 → 先添加来源规则 → 再删除公网规则 → 检查剩余覆盖。
restrict_rule_to_source() {
  local source="$1"
  local port="$2"
  local proto="${3:-tcp}"
  local -a extra=()

  validate_source "$source"
  validate_port "$port"
  validate_protocol "$proto"
  mapfile -d '' -t extra < <(comment_args)

  guard_restrict_ssh "$source" "$port" "$proto"

  log "收紧规则：仅允许 ${source} 访问 ${port}/${proto}"

  # 先添加来源规则：若来源无效，ufw 会报错，此时不会删除任何既有规则。
  ufw_run allow from "$source" to any port "$port" proto "$proto" "${extra[@]}"
  log "已添加来源规则：allow from ${source} to any port ${port} proto ${proto}"

  remove_exact_public_rules "$port" "$proto"

  log "正在检查是否仍存在面向任意来源的放行规则"
  check_public_allow_for_port "$port" "$proto" || die "仍有公网规则覆盖目标端口，收紧未完成；请检查以上规则。"
  log "目标端口的公网放行已移除。其他指定来源规则保持不变。"

  log "当前规则如下："
  show_rules
}

# ------------------------------------------------------------------------------
# check 子命令的各项检查
# ------------------------------------------------------------------------------

read_ufw_default() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k { gsub(/"/, "", $2); print $2 }' "$UFW_DEFAULTS_FILE" 2>/dev/null || true
}

check_default_policy() {
  local input output forward

  input="$(read_ufw_default DEFAULT_INPUT_POLICY)"
  output="$(read_ufw_default DEFAULT_OUTPUT_POLICY)"
  forward="$(read_ufw_default DEFAULT_FORWARD_POLICY)"

  log "默认策略（来自 ${UFW_DEFAULTS_FILE}）："
  printf '  - incoming: %s\n  - outgoing: %s\n  - routed  : %s\n' "${input:-unknown}" "${output:-unknown}" "${forward:-unknown}"

  if [[ "$input" == "ACCEPT" ]]; then
    warn "默认入站策略为 ACCEPT：所有未匹配规则的入站流量都会被放行！"
  fi
}

check_ipv6_setting() {
  local ipv6=""
  ipv6="$(read_ufw_default IPV6)"

  if [[ "${ipv6,,}" == "no" ]]; then
    if command -v ip >/dev/null 2>&1 && [[ -n "$(ip -6 addr show scope global 2>/dev/null || true)" ]]; then
      warn "${UFW_DEFAULTS_FILE} 中 IPV6=no，但本机存在全局 IPv6 地址：IPv6 流量不受 UFW 保护。"
    else
      log "IPv6 规则：未启用（IPV6=no，本机未检测到全局 IPv6 地址）"
    fi
  else
    log "IPv6 规则：已启用（IPV6=${ipv6:-yes}）"
  fi
}

# 报告某端口的放行情况：公网 / 仅限来源 / 未放行
report_port_coverage() {
  local label="$1"
  local port="$2"
  local proto="$3"
  local matched="" public=""

  matched="$(matching_allow_rules "$port" "$proto" all)" || die "无法读取防火墙规则。"
  public="$(matching_allow_rules "$port" "$proto" public)" || die "无法读取防火墙规则。"

  if [[ -n "$public" ]]; then
    log "${label} ${port}/${proto}：已对任意来源放行（$(cut -d'|' -f3- <<< "$public" | head -n1)）"
  elif [[ -n "$matched" ]]; then
    log "${label} ${port}/${proto}：仅对指定来源放行：$(cut -d'|' -f2 <<< "$matched" | sort -u | paste -sd' ' -)"
  else
    warn "${label} ${port}/${proto}：未检测到放行规则"
  fi
}

check_high_risk_rules() {
  local all_ports="" risky="" port raw
  local action dir src dport proto app rules matches

  rules="$(list_added_rules)" || die "无法读取防火墙规则。"

  # 全端口放行（例如 ufw allow from any / ufw allow proto tcp from any）
  while IFS='|' read -r action dir src dport proto app raw; do
    if [[ ( "$action" == "allow" || "$action" == "limit" ) && "$dir" == "in" && "$dport" == "any" && -z "$app" ]] && is_any_source "$src"; then
      all_ports+="${raw}"$'\n'
    fi
  done <<< "$rules"

  # 常见高风险端口（覆盖范围/列表/应用/不带协议规则；全端口规则单独报告，不重复）
  for port in "${HIGH_RISK_PORTS[@]}"; do
    matches="$(matching_allow_rules "$port" "any" public | cut -d'|' -f3-)" \
      || die "无法读取防火墙规则或应用端口。"
    while IFS= read -r raw; do
      [[ -n "$raw" ]] || continue
      if grep -qxF -- "$raw" <<< "$all_ports"; then
        continue
      fi
      risky+="$(printf '  端口 %-6s <- ufw %s' "$port" "$raw")"$'\n'
    done <<< "$matches"
  done

  if [[ -n "$all_ports" ]]; then
    warn "检测到对任意来源放行所有端口的规则（极高风险）："
    sed '/^$/d; s/^/  ufw /' <<< "$all_ports" >&2
  fi

  if [[ -n "$risky" ]]; then
    warn "检测到常见高风险端口对任意来源开放，请确认是否确实需要："
    printf '%s' "$risky" >&2
  fi

  if [[ -z "$all_ports" && -z "$risky" ]]; then
    log "未检测到常见高风险公网开放规则"
  fi
}

check_docker_ports() {
  local name="" ports="" entry="" host_part="" bind_addr="" exposed=0
  local -a entries=()

  command -v docker >/dev/null 2>&1 || return 0
  if ! docker info >/dev/null 2>&1; then
    warn "已安装 Docker，但当前无法访问 Docker daemon，跳过 Docker 发布端口检查。"
    return 0
  fi

  log "Docker 发布端口检查（Docker 发布的端口不受 UFW 规则约束）："
  while IFS='|' read -r name ports; do
    [[ -n "$ports" ]] || continue
    IFS=',' read -r -a entries <<< "$ports"
    for entry in "${entries[@]}"; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      [[ "$entry" == *"->"* ]] || continue
      host_part="${entry%%->*}"
      bind_addr="${host_part%:*}"
      bind_addr="${bind_addr#[}"
      bind_addr="${bind_addr%]}"
      case "$bind_addr" in
        127.*|::1|localhost) ;;
        *)
          printf '  %-24s %s\n' "$name" "$entry" >&2
          exposed=$((exposed + 1))
          ;;
      esac
    done
  done < <(docker ps --format '{{.Names}}|{{.Ports}}')

  if (( exposed > 0 )); then
    warn "以上 ${exposed} 个 Docker 端口发布在非回环地址，UFW 规则拦不住它们。如无需对外，请改为绑定 127.0.0.1:端口，或在 DOCKER-USER 链中限制。"
  else
    log "  未发现发布在非回环地址的 Docker 端口"
  fi
}

# 日常巡检
check_firewall() {
  local ssh_port=""

  log "脚本版本：${SCRIPT_VERSION}"

  if ufw_is_active; then
    log "UFW 状态：active"
  else
    warn "UFW 状态：inactive（以下规则检查基于已添加但未生效的规则）"
  fi

  check_default_policy
  check_ipv6_setting

  detect_ssh_ports
  log "检查 SSH 端口放行状态（探测到：${SSH_PORTS[*]}；来源：${SSH_PORT_SOURCES}）："
  for ssh_port in "${SSH_PORTS[@]}"; do
    report_port_coverage "SSH 端口" "$ssh_port" "tcp"
  done

  report_port_coverage "默认业务端口" "$DEFAULT_TCP_PORT" "$DEFAULT_PROTOCOL"

  check_high_risk_rules
  check_docker_ports

  echo
  log "完整规则如下："
  show_rules
}

# 主入口：根据子命令分发具体动作。
main() {
  local cmd="${1:-}"

  case "$cmd" in
    -h|--help|help|'')
      usage
      return 0
      ;;
    version|--version|-v)
      show_version
      return 0
      ;;
  esac

  shift
  require_root
  require_ufw
  parse_cmd_args "$@"

  case "$cmd" in
    init)
      init_ufw
      ;;
    status)
      show_status
      ;;
    check)
      check_firewall
      ;;
    add)
      (( ${#POS[@]} >= 1 )) || die "缺少端口参数。用法：sudo $SCRIPT_NAME add <port> [tcp|udp] [--comment TEXT]"
      add_rule "${POS[0]}" "${POS[1]:-tcp}"
      ;;
    del)
      (( ${#POS[@]} >= 1 )) || die "缺少端口参数。用法：sudo $SCRIPT_NAME del <port> [tcp|udp] [--yes]"
      delete_rule "${POS[0]}" "${POS[1]:-tcp}"
      ;;
    add-from)
      (( ${#POS[@]} >= 2 )) || die "缺少参数。用法：sudo $SCRIPT_NAME add-from <source_ip_or_cidr> <port> [tcp|udp] [--comment TEXT]"
      add_rule_from "${POS[0]}" "${POS[1]}" "${POS[2]:-tcp}"
      ;;
    restrict)
      (( ${#POS[@]} >= 2 )) || die "缺少参数。用法：sudo $SCRIPT_NAME restrict <source_ip_or_cidr> <port> [tcp|udp] [--comment TEXT] [--yes]"
      restrict_rule_to_source "${POS[0]}" "${POS[1]}" "${POS[2]:-tcp}"
      ;;
    del-from)
      (( ${#POS[@]} >= 2 )) || die "缺少参数。用法：sudo $SCRIPT_NAME del-from <source_ip_or_cidr> <port> [tcp|udp] [--yes]"
      delete_rule_from "${POS[0]}" "${POS[1]}" "${POS[2]:-tcp}"
      ;;
    *)
      die "未知命令：$cmd。使用 --help 查看帮助"
      ;;
  esac
}

main "$@"
