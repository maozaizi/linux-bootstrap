#!/usr/bin/env bash
# server-security-audit.sh — SSH 公钥认证收口与主机暴露面检查。
# Version: 1.2.5 | Updated: 2026-11-05
# 只读检查（root）：bash server-security-audit.sh --audit-only。
# SSH 收口（root）：bash server-security-audit.sh；其他选项见 --help。
# 默认修改 SSH；--audit-only 只检查。请先在新终端验证公钥登录和 sudo。
# 保留原有 root 登录限制（含旧版收口文件）；仅收紧认证方式。
# 00-key-only-auth.conf 优先于 Bootstrap；验证或应用失败会恢复原配置。
# 公钥预检不能替代真实登录测试（不完整评估账户限制和 AllowGroups 等规则）。

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.2.5"
readonly SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly SSH_DROPIN_FILE="${SSH_DROPIN_DIR}/00-key-only-auth.conf"
# 覆盖 IPv4 / IPv6 测试来源；验证时另加入当前 SSH 来源。
readonly -a VERIFY_ADDRS=("127.0.0.1" "192.0.2.1" "::1" "2001:db8::1")

AUDIT_ONLY=0
ASSUME_YES=0
FORCE=0
SSHD_BIN=""
CANDIDATE_FILE=""
LOGIN_USERS=()
READY_USERS=()

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$CANDIDATE_FILE" && -f "$CANDIDATE_FILE" ]]; then
    rm -f "$CANDIDATE_FILE"
  fi
  return 0
}
trap cleanup EXIT
trap 'rc=$?; printf "\033[1;31m[ERR ]\033[0m 第 %s 行执行失败（退出码 %s）\n" "$LINENO" "$rc" >&2' ERR

usage() {
  cat <<'EOF'
用法：
  sudo ./server-security-audit.sh [选项]

选项：
  --audit-only          只审计，不写入 SSH 配置
  -y, --yes             跳过确认提示（非交互环境必须指定）
  --force               即使没有任何账户拥有可用公钥也强制应用（危险，可能锁死 SSH）
  -h, --help            显示帮助
  -v, --version         显示版本

示例：
  # 检查并关闭 SSH 密码登录（带锁死保护和确认），然后显示当前端口情况
  sudo ./server-security-audit.sh

  # 仅查看，不修改 SSH 配置
  sudo ./server-security-audit.sh --audit-only

  # 自动化场景
  sudo ./server-security-audit.sh --yes

行为边界：
  - 唯一修改动作：关闭 SSH 密码和键盘交互认证，强制 publickey
  - 写入前会检查是否至少有一个可登录账户拥有可用公钥，否则拒绝执行
  - 不修改 UFW、nftables、iptables、Docker、云厂商安全组或任何业务服务
  - 端口及防火墙信息只展示，不执行白名单判断或端口调整
EOF
}

require_root() {
  [[ ${EUID:-0} -eq 0 ]] || die "请以 root 运行，例如：sudo ./${SCRIPT_NAME}"
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "此脚本仅支持 Linux。"
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"

  local os_id=""
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-unknown}"
  case "$os_id" in
    debian|ubuntu) ;;
    *) die "当前系统为 ${os_id}；此脚本仅支持 Debian/Ubuntu。" ;;
  esac
}

find_sshd() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
    return
  fi

  local candidate=""
  for candidate in /usr/sbin/sshd /sbin/sshd; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  return 1
}

# sshd -t / sshd -T 需要 /run/sshd。Ubuntu 24.04 使用 ssh.socket 按需启动，
# ssh.service 未运行时该目录不存在，会导致 "Missing privilege separation directory"。
ensure_privsep_dir() {
  if [[ ! -d /run/sshd ]]; then
    install -d -m 0755 /run/sshd
    info "已创建运行时目录 /run/sshd（sshd -t/-T 需要）。"
  fi
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --audit-only)
        AUDIT_ONLY=1
        shift
        ;;
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -v|--version)
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        exit 0
        ;;
      *)
        die "未知参数：$1。使用 --help 查看帮助。"
        ;;
    esac
  done
}

# 独立经 sudo 运行时，也尽量恢复当前 SSH 来源。
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

# ------------------------------------------------------------------------------
# sshd 有效配置
# ------------------------------------------------------------------------------
effective_sshd_config() {
  local user_name="$1"
  local addr="$2"
  local host_name=""
  host_name="$(hostname 2>/dev/null || echo localhost)"
  "$SSHD_BIN" -T -C "user=${user_name},host=${host_name},addr=${addr}"
}

sshd_value() {
  local config="$1"
  local key="$2"
  awk -v wanted="$key" '$1 == wanted { print $2; exit }' <<< "$config"
}

# 可登录账户：root + UID>=1000 且 shell 有效的账户
list_login_users() {
  printf 'root\n'
  getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 != "" && $7 !~ /(nologin|false)$/ { print $1 }'
}

config_is_key_only() {
  local config="$1"
  local password_auth="" keyboard_auth="" pubkey_auth="" auth_methods=""

  password_auth="$(sshd_value "$config" passwordauthentication)"
  keyboard_auth="$(sshd_value "$config" kbdinteractiveauthentication)"
  pubkey_auth="$(sshd_value "$config" pubkeyauthentication)"
  auth_methods="$(sshd_value "$config" authenticationmethods)"

  [[ "$password_auth" == "no" ]] || return 1
  [[ "$keyboard_auth" == "no" ]] || return 1
  [[ "$pubkey_auth" == "yes" ]] || return 1
  [[ "$auth_methods" == "publickey" ]] || return 1
  # AuthenticationMethods 已限制为 publickey，无需放宽或重写 PermitRootLogin。
  return 0
}

# 输出所有未达到 publickey-only 的 "用户@来源地址" 组合（无输出表示全部达标）
key_only_failures() {
  local user="" addr="" config=""
  local -a addresses=("${VERIFY_ADDRS[@]}")
  [[ -z "${SSH_CONNECTION:-}" ]] || addresses+=("${SSH_CONNECTION%% *}")
  for user in "${LOGIN_USERS[@]}"; do
    for addr in "${addresses[@]}"; do
      if ! config="$(effective_sshd_config "$user" "$addr" 2>/dev/null)"; then
        printf '%s@%s（无法读取有效配置）\n' "$user" "$addr"
        continue
      fi
      if ! config_is_key_only "$config" "$user"; then
        printf '%s@%s\n' "$user" "$addr"
      fi
    done
  done
}

show_ssh_effective_state() {
  local label="$1"
  local user="" addr="" config="" root_login="" failures=""
  local -a addresses=("${VERIFY_ADDRS[@]}")
  [[ -z "${SSH_CONNECTION:-}" ]] || addresses+=("${SSH_CONNECTION%% *}")

  printf '\n========== SSH 有效配置：%s ==========\n' "$label"
  printf '%-16s %-12s %-9s %-9s %-8s %-13s %s\n' \
    "User" "Source" "Password" "KbdInter" "Pubkey" "AuthMethods" "RootLogin"

  for user in "${LOGIN_USERS[@]}"; do
    for addr in "${addresses[@]}"; do
      config="$(effective_sshd_config "$user" "$addr")" || die "无法读取 ${user}@${addr} 的 sshd 最终生效配置。"
      root_login="-"
      if [[ "$user" == "root" ]]; then
        root_login="$(sshd_value "$config" permitrootlogin)"
      fi
      printf '%-16s %-12s %-9s %-9s %-8s %-13s %s\n' \
        "$user" "$addr" \
        "$(sshd_value "$config" passwordauthentication)" \
        "$(sshd_value "$config" kbdinteractiveauthentication)" \
        "$(sshd_value "$config" pubkeyauthentication)" \
        "$(sshd_value "$config" authenticationmethods)" \
        "${root_login:-?}"
    done
  done

  failures="$(key_only_failures)"
  if [[ -z "$failures" ]]; then
    ok "所有可登录账户在上述来源地址下均为 publickey-only。"
  else
    warn "以下组合尚未达到 publickey-only 状态："
    printf '  - %s\n' $failures >&2 || true
  fi
}

# ------------------------------------------------------------------------------
# 锁死保护：公钥就绪检查
# ------------------------------------------------------------------------------
expand_authkeys_path() {
  local path="$1" user="$2" home="$3" uid="$4"
  path="${path//'%%'/$'\x01'}"
  path="${path//'%h'/$home}"
  path="${path//'%u'/$user}"
  path="${path//'%U'/$uid}"
  path="${path//$'\x01'/%}"
  if [[ "$path" != /* ]]; then
    path="${home}/${path}"
  fi
  printf '%s\n' "$path"
}

has_public_key_line() {
  command -v ssh-keygen >/dev/null 2>&1 || return 1
  ssh-keygen -lf "$1" >/dev/null 2>&1
}

# 输出 yes / no / unknown
user_key_status() {
  local user="$1"
  local config="" home="" uid="" tpl="" path="" cmd="" found=0

  if ! config="$(effective_sshd_config "$user" "127.0.0.1" 2>/dev/null)"; then
    echo unknown
    return 0
  fi

  home="$(getent passwd "$user" | cut -d: -f6)"
  uid="$(id -u "$user" 2>/dev/null || true)"

  if [[ -n "$home" && -n "$uid" ]]; then
    while IFS= read -r tpl; do
      [[ -n "$tpl" && "$tpl" != "none" ]] || continue
      path="$(expand_authkeys_path "$tpl" "$user" "$home" "$uid")"
      if [[ -r "$path" ]] && has_public_key_line "$path"; then
        found=1
        break
      fi
    done < <(awk '$1 == "authorizedkeysfile" { for (i = 2; i <= NF; i++) print $i }' <<< "$config")
  fi

  if ((found == 1)); then
    echo yes
    return 0
  fi

  cmd="$(sshd_value "$config" authorizedkeyscommand)"
  if [[ -n "$cmd" && "$cmd" != "none" ]]; then
    echo unknown
  else
    echo no
  fi
}

# 简化的 AllowUsers 判断：未设置视为允许；user@host 形式只比较用户部分
allowed_by_allowusers() {
  local config="$1" user="$2"
  local patterns="" pat=""
  patterns="$(awk '$1 == "allowusers" { for (i = 2; i <= NF; i++) print $i }' <<< "$config")"

  if [[ -z "$patterns" ]]; then
    return 0
  fi

  while IFS= read -r pat; do
    pat="${pat%%@*}"
    # shellcheck disable=SC2053
    if [[ "$user" == $pat ]]; then
      return 0
    fi
  done <<< "$patterns"
  return 1
}

in_array() {
  local needle="$1"
  shift
  local item=""
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

audit_key_readiness() {
  local user="" status="" note="" label="" config=""
  READY_USERS=()

  printf '\n========== 公钥登录就绪检查 ==========\n'
  printf '%-20s %-8s %s\n' "User" "Key" "Note"

  for user in "${LOGIN_USERS[@]}"; do
    status="$(user_key_status "$user")"
    config="$(effective_sshd_config "$user" "127.0.0.1" 2>/dev/null || true)"

    case "$status" in
      yes)     label="yes" ;;
      unknown) label="unknown" ;;
      *)       label="no" ;;
    esac

    if [[ -n "$config" ]] && ! allowed_by_allowusers "$config" "$user"; then
      printf '%-20s %-8s %s\n' "$user" "$label" "被 AllowUsers 排除，无法通过 SSH 登录"
      continue
    fi
    if [[ "$user" == root && "$(sshd_value "$config" permitrootlogin)" == no ]]; then
      printf '%-20s %-8s %s\n' "$user" "$label" "root SSH 登录已禁止，不计入就绪账户"
      continue
    fi

    note=""
    case "$status" in
      yes)
        READY_USERS+=("$user")
        ;;
      unknown)
        note="公钥来源或配置无法在本机验证，不计入已就绪账户"
        ;;
      *)
        note="未找到有效公钥"
        ;;
    esac
    printf '%-20s %-8s %s\n' "$user" "$label" "$note"
  done

  if ((${#READY_USERS[@]} > 0)); then
    ok "具备公钥登录条件的账户：${READY_USERS[*]}"
  else
    warn "没有任何账户具备可用公钥。"
  fi
}

guard_lockout() {
  local current="${SUDO_USER:-root}"

  if ((${#READY_USERS[@]} == 0)); then
    if ((FORCE == 1)); then
      warn "--force：没有任何账户具备可用公钥，仍将继续。关闭当前会话后可能无法再登录！"
    else
      die "拒绝执行：没有任何账户具备可用公钥，关闭密码登录会导致无法登录。请先配置 authorized_keys，或明确使用 --force。"
    fi
  fi

  if ! in_array "$current" "${READY_USERS[@]}"; then
    warn "当前操作用户 '${current}' 没有可用公钥（或被 AllowUsers 排除）。应用后该用户将无法再通过 SSH 登录。"
  fi
}

confirm_apply() {
  local answer=""

  if ((ASSUME_YES == 1)); then
    return 0
  fi

  if [[ -t 0 && -t 1 ]]; then
    warn "即将写入 ${SSH_DROPIN_FILE} 并重载 SSH：此后 SSH 仅允许公钥登录。"
    warn "请保持当前会话不要关闭，并在新终端验证公钥登录成功。"
    read -r -p "确认继续？[y/N]: " answer || die "读取确认失败；未做修改。"
    case "${answer,,}" in
      y|yes) ;;
      *) die "已取消，未做修改。" ;;
    esac
  else
    die "非交互环境需要显式传入 --yes 才会修改 SSH 配置。"
  fi
}

# ------------------------------------------------------------------------------
# SSH 服务重载
# ------------------------------------------------------------------------------
ssh_unit_name() {
  local candidate=""
  for candidate in ssh sshd; do
    if systemctl cat "${candidate}.service" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

reload_ssh_service() {
  local unit=""

  if command -v systemctl >/dev/null 2>&1 && unit="$(ssh_unit_name)"; then
    if systemctl is-active --quiet "$unit"; then
      systemctl reload "$unit" || systemctl restart "$unit" || return 1
      return 0
    fi
    # Ubuntu 24.04: ssh.service 可能由 ssh.socket 按需启动，未运行时无需 reload，
    # 下次连接启动服务时会读取新配置。
    warn "${unit}.service 当前未运行（可能由 ssh.socket 按需启动）；新配置将在下次启动时生效。"
    return 0
  fi

  if command -v service >/dev/null 2>&1; then
    service ssh reload 2>/dev/null || service sshd reload || die "无法重载 SSH 服务，请手动执行 reload。"
    return 0
  fi

  die "无法识别 SSH 服务管理方式，请手动重载 SSH 服务。"
}

enforce_key_only_ssh() (
  committed=0 runtime_touched=0 staged=0
  install -d -m 0755 "$SSH_DROPIN_DIR"
  [[ ! -L "$SSH_DROPIN_FILE" ]] || die "拒绝替换符号链接：$SSH_DROPIN_FILE"
  workdir="$(mktemp -d "$SSH_DROPIN_DIR/.key-only.XXXXXX")"
  CANDIDATE_FILE="$workdir/candidate"
  rollback_key_only() {
    local rc=$? failed=0
    trap - EXIT
    if [[ "$committed" == 0 && "$staged" == 1 ]]; then
      if [[ -f "$workdir/original" ]]; then
        mv -f "$workdir/original" "$SSH_DROPIN_FILE" || failed=1
      else
        rm -f "$SSH_DROPIN_FILE" || failed=1
      fi
      if [[ "$runtime_touched" == 1 ]]; then reload_ssh_service || failed=1; fi
      warn "SSH 收口失败，已尝试恢复原配置。"
    fi
    if [[ "$failed" == 1 ]]; then
      warn "回滚未全部完成，请检查 SSH 服务；备份目录：$workdir"
    else
      rm -rf -- "$workdir"
    fi
    exit "$rc"
  }
  trap rollback_key_only EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ ! -f "$SSH_DROPIN_FILE" ]] || cp -p "$SSH_DROPIN_FILE" "$workdir/original"

  cat > "$CANDIDATE_FILE" <<'EOF'
# Managed by server-security-audit.sh
# SSH accepts public-key authentication only; existing root restrictions remain.
# ChallengeResponseAuthentication is a deprecated alias of KbdInteractiveAuthentication;
# it is kept here for older sshd versions.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
EOF
  # 迁移旧版文件时，保留其中的 root 策略及其 Match 作用域。
  if [[ -f "$workdir/original" ]]; then
    awk '
      { line=$0; sub(/^[ \t]+/, "", line); split(line, fields, /[ \t=]+/); key=tolower(fields[1]) }
      key == "match" { context=$0 }
      key == "permitrootlogin" {
        if (context != "") { print context; matched=1 }
        print
      }
      END { if (matched) print "Match all" }
    ' "$workdir/original" >> "$CANDIDATE_FILE"
  fi
  cat >> "$CANDIDATE_FILE" <<'EOF'

# A later bootstrap drop-in may contain a root-only password exception.
# sshd uses the first value it obtains and this file is read first (00-*),
# but Match blocks are evaluated per user, so define the root policy here too.
Match User root
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitEmptyPasswords no
  AuthenticationMethods publickey

# 所有账户在首个适用的 Match 中明确收口，避免后续来源例外放宽认证。
Match all
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitEmptyPasswords no
  AuthenticationMethods publickey
EOF
  chmod 0644 "$CANDIDATE_FILE"
  if [[ ! -f "$SSH_DROPIN_FILE" ]] || ! cmp -s "$CANDIDATE_FILE" "$SSH_DROPIN_FILE"; then
    staged=1
    mv -f "$CANDIDATE_FILE" "$SSH_DROPIN_FILE"
  fi
  "$SSHD_BIN" -t || die "SSH 配置语法检查失败。"
  failures="$(key_only_failures)"
  [[ -z "$failures" ]] || die "以下账户/来源的 SSH 策略存在冲突：$failures"
  runtime_touched=1
  reload_ssh_service || die "无法重载或重启 SSH 服务。"
  committed=1
  ok "SSH publickey-only 策略已处理。"
)

# ------------------------------------------------------------------------------
# 监听端口 / UFW / Docker（只读）
# ------------------------------------------------------------------------------
endpoint_address() {
  local endpoint="$1"
  local address="${endpoint%:*}"
  address="${address#[}"
  address="${address%]}"
  printf '%s\n' "$address"
}

endpoint_port() {
  local endpoint="$1"
  printf '%s\n' "${endpoint##*:}"
}

is_loopback_address() {
  local address="$1"
  [[ "$address" == "127."* || "$address" == "::1" || "$address" == "localhost" ]]
}

audit_listeners() {
  local netid="" state="" recv_q="" send_q="" local_endpoint="" peer_endpoint="" process_info=""
  local proto="" address="" port="" scope=""

  command -v ss >/dev/null 2>&1 || die "未找到 ss；请确认 iproute2 已安装。"

  printf '\n========== TCP/UDP 监听端口 ==========\n'
  printf '%-5s %-30s %-8s %-12s %s\n' "Proto" "Address" "Port" "Scope" "Process"

  while read -r netid state recv_q send_q local_endpoint peer_endpoint process_info; do
    [[ -n "$netid" ]] || continue
    case "$netid" in
      tcp|tcp6) proto="tcp" ;;
      udp|udp6) proto="udp" ;;
      *) continue ;;
    esac

    address="$(endpoint_address "$local_endpoint")"
    port="$(endpoint_port "$local_endpoint")"
    [[ "$port" =~ ^[0-9]+$ ]] || continue

    if is_loopback_address "$address"; then
      scope="仅本机"
    else
      scope="非回环监听"
    fi

    printf '%-5s %-30s %-8s %-12s %s\n' "$proto" "$address" "$port" "$scope" "${process_info:--}"
  done < <(ss -H -lntup)

  info "“非回环监听”只表示绑定在非本机地址，是否可从外网访问还取决于 UFW、云安全组等；脚本未关闭端口或修改任何规则。"
}

audit_ufw() {
  printf '\n========== UFW 当前状态（只读） ==========\n'
  if ! command -v ufw >/dev/null 2>&1; then
    info "未安装 UFW；跳过。"
    return
  fi

  ufw status verbose || true
  printf '\n'
  ufw status numbered || true
  info "UFW 信息仅作展示；脚本未增加、删除或修改规则。"
}

show_docker_user_chain() {
  local rules=""
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -S DOCKER-USER >/dev/null 2>&1 || return 0

  rules="$(iptables -S DOCKER-USER 2>/dev/null | grep '^-A DOCKER-USER' | grep -v -- '-j RETURN$' || true)"
  if [[ -z "$rules" ]]; then
    info "DOCKER-USER 链中没有自定义限制规则（Docker 发布的端口不会被额外限制）。"
  else
    info "DOCKER-USER 链中的自定义规则："
    printf '  %s\n' "$rules"
  fi
}

show_docker_ports() {
  local name="" ports="" entry="" host_part="" bind_addr="" scope=""
  local rows=0 exposed=0
  local -a entries=()

  printf '\n========== Docker 发布端口（只读） ==========\n'
  if ! command -v docker >/dev/null 2>&1; then
    info "未安装 Docker；跳过。"
    return
  fi

  if ! docker info >/dev/null 2>&1; then
    warn "Docker 未运行或当前无法访问 Docker daemon。"
    return
  fi

  printf '%-28s %-44s %s\n' "Container" "Published" "Scope"
  while IFS='|' read -r name ports; do
    [[ -n "$ports" ]] || continue
    IFS=',' read -r -a entries <<< "$ports"
    for entry in "${entries[@]}"; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      [[ "$entry" == *"->"* ]] || continue
      host_part="${entry%%->*}"
      bind_addr="$(endpoint_address "$host_part")"
      if is_loopback_address "$bind_addr"; then
        scope="仅本机"
      else
        scope="非回环（绕过 UFW）"
        exposed=$((exposed + 1))
      fi
      rows=$((rows + 1))
      printf '%-28s %-44s %s\n' "$name" "$entry" "$scope"
    done
  done < <(docker ps --format '{{.Names}}|{{.Ports}}')

  if ((rows == 0)); then
    info "当前没有运行中的容器发布端口。"
  fi

  if ((exposed > 0)); then
    warn "有 ${exposed} 个端口发布在非回环地址。Docker 通过自己的 iptables 规则放行这些端口，不受 UFW 规则约束（ufw deny 拦不住）。"
    warn "如不需要对外，请改为绑定 127.0.0.1:端口，或在 DOCKER-USER 链中限制；本脚本不会修改。"
  fi

  show_docker_user_chain
  info "Docker 发布端口仅作展示；脚本未修改容器或端口映射。"
}

main() {
  parse_args "$@"
  require_root
  require_linux
  export SSH_CONNECTION="$(ssh_context)"

  SSHD_BIN="$(find_sshd)" || die "未找到 sshd；请确认 openssh-server 已安装。"
  ensure_privsep_dir
  "$SSHD_BIN" -t || die "当前 sshd 配置检查失败（语法错误或缺少运行条件），请先修复后再运行。"

  mapfile -t LOGIN_USERS < <(list_login_users)

  info "脚本版本：${SCRIPT_VERSION}"
  show_ssh_effective_state "修改前"
  audit_key_readiness

  if ((AUDIT_ONLY == 1)); then
    info "--audit-only：跳过 SSH 配置写入。"
  else
    guard_lockout
    confirm_apply
    enforce_key_only_ssh
    show_ssh_effective_state "修改后"
  fi

  audit_listeners
  audit_ufw
  show_docker_ports

  printf '\n========== 完成 ==========\n'
  if ((AUDIT_ONLY == 1)); then
    ok "审计完成。未对服务器执行任何配置修改。"
  else
    ok "检查完成。除 SSH key-only 配置外，未对服务器执行其他修改。请在新终端验证公钥登录后再关闭当前会话。"
  fi
}

main "$@"
