#!/usr/bin/env bash
# bootstrap-debian.sh — Debian / Ubuntu 新服务器初始化
# Version: 1.6.2 | Updated: 2026-11-05
# 支持 Ubuntu 22.04 / 24.04、Debian 12 / 13，需 root 和 systemd。
# 仅安装软件：bash bootstrap-debian.sh --packages-only（清单为同目录 soft-list）。
# 只读预检：使用同一公钥设置，追加 --check。
#
# 用法：BOOTSTRAP_PUBKEY_FILE=/root/id_ed25519.pub bash bootstrap-debian.sh
# 也可通过 BOOTSTRAP_PUBKEY 传入单行公钥；需要密码时会在系统变更前交互确认。
# 默认创建 maozaizi（zsh + sudo），禁用普通用户 SSH 密码认证，保留 root 密码兜底。
# SSH 策略使用 10-bootstrap.conf（早于常见的 50-cloud-init.conf），自动迁移旧 99 文件。
# FORCE_RUN=1 绕过总完成标记；用户、公钥、软件包和 SSH 会重新检查。
# 完成后请在新终端验证登录，再关闭当前会话。其余配置见下方环境变量。

VERSION="1.6.2"
LAST_MODIFIED="2026-11-05"
SUPPORTED_DISTROS="ubuntu-22.04 ubuntu-24.04 debian-12 debian-13"
set -Eeuo pipefail

# 避免 needrestart（Ubuntu 22.04+/24.04 默认自带）在 apt 之后弹出交互提示导致脚本卡住
export NEEDRESTART_MODE=a

# =========================
# Config (可通过环境变量覆盖)
# =========================
BOOTSTRAP_USER="${BOOTSTRAP_USER:-maozaizi}"
BOOTSTRAP_SHELL="${BOOTSTRAP_SHELL:-/usr/bin/zsh}"
BOOTSTRAP_TZ="${BOOTSTRAP_TZ:-Asia/Shanghai}"

# 安全加固选项（生产环境建议开启）
HARDEN_SSH="${HARDEN_SSH:-1}"          # 1=写入 sshd_config.d 加固配置并重载 sshd
DISABLE_SSH_PASSWORD="${DISABLE_SSH_PASSWORD:-1}"  # 1=禁用 SSH 密码登录（建议与公钥登录配套）
DISABLE_ROOT_SSH="${DISABLE_ROOT_SSH:-0}"          # 1=禁用 root SSH 登录（推荐）
DISABLE_ROOT_SSH_PASSWORD="${DISABLE_ROOT_SSH_PASSWORD:-0}" # 1=禁用 root 的 SSH 密码登录（默认不禁用，作为兜底）
SSH_PORT="${SSH_PORT:-22}"            # 若你改过 SSH 端口，可在环境变量覆盖

# Shell 体验（root 也统一）
CONFIGURE_SYSTEM_ZSHRC="${CONFIGURE_SYSTEM_ZSHRC:-1}"   # 1=写入 /etc/zsh/zshrc（所有用户生效）
SET_ROOT_SHELL_ZSH="${SET_ROOT_SHELL_ZSH:-0}"           # 1=将 root 的登录 shell 切换为 zsh（谨慎开启）
ROOT_SHELL="${ROOT_SHELL:-/usr/bin/zsh}"

# 允许重新执行（用于变更公钥/修复配置）
FORCE_RUN="${FORCE_RUN:-0}"           # 1=忽略 DONE_FILE 并继续执行

# SSH 公钥：二选一
# 1) BOOTSTRAP_PUBKEY="ssh-ed25519 AAAA... comment"
BOOTSTRAP_PUBKEY="${BOOTSTRAP_PUBKEY:-}"
# 2) BOOTSTRAP_PUBKEY_FILE="/path/to/id_ed25519.pub"
BOOTSTRAP_PUBKEY_FILE="${BOOTSTRAP_PUBKEY_FILE:-}"

# 预采集并校验后的用户密码（仅保存在当前 shell 进程内存中）
BOOTSTRAP_USER_PASSWORD=""
VALIDATED_PUBKEY=""

collect_bootstrap_password() {
  local password1=""
  local password2=""

  [[ -t 0 ]] || die "Preflight failed: no interactive TTY available for password input. No changes were made."

  info "Preflight: password for user '$BOOTSTRAP_USER' is required for this run and will be collected now before any system changes."
  info "Preflight: if the two password entries do not match, the script will exit immediately without performing bootstrap actions."

  read -rsp "Enter password for user '$BOOTSTRAP_USER': " password1 || die "Preflight failed: unable to read password from terminal. No changes were made."
  echo
  read -rsp "Confirm password for user '$BOOTSTRAP_USER': " password2 || die "Preflight failed: unable to read password confirmation from terminal. No changes were made."
  echo

  [[ -n "$password1" ]] || die "Preflight failed: password cannot be empty. No changes were made."
  [[ "$password1" == "$password2" ]] || die "Preflight failed: password entries do not match. No changes were made."

  BOOTSTRAP_USER_PASSWORD="$password1"
  password1=""
  password2=""
  log "Preflight password confirmation passed"
}

# 幂等标记（全局只跑一次）
STATE_DIR="/var/local/bootstrap"
DONE_FILE="${STATE_DIR}/done"

# ssh.socket 端口同步用的 drop-in（仅在系统使用 socket activation 时才会用到）
SSH_SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SSH_SOCKET_DROPIN_FILE="${SSH_SOCKET_DROPIN_DIR}/99-bootstrap-port.conf"

# 配置文件是数据，不作为 shell 代码执行。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
SOFT_LIST_FILE="${SOFT_LIST_FILE:-$SCRIPT_DIR/soft-list}"
CORE_PKGS=()

# =========================
# Utils
# =========================
info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
log() { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-0} -eq 0 ]] || die "Please run as root."
}

ensure_sudo_installed() {
  command -v sudo >/dev/null 2>&1 || die "sudo is required; include it in $SOFT_LIST_FILE."
}

# 每行一个包名，支持空行、注释、CRLF 和最后一行无换行。
load_package_list() {
  [[ -f "$SOFT_LIST_FILE" && -r "$SOFT_LIST_FILE" ]] || die "Cannot read package list: $SOFT_LIST_FILE"
  CORE_PKGS=()
  local line number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$ ]] \
      || die "Invalid package name at ${SOFT_LIST_FILE}:${number}: $line"
    [[ "$line" != *- && "${line%%:*}" != *- ]] \
      || die "APT removal operands are forbidden at ${SOFT_LIST_FILE}:${number}: $line"
    CORE_PKGS+=("$line")
  done < "$SOFT_LIST_FILE"
  (( ${#CORE_PKGS[@]} > 0 )) || die "Package list is empty: $SOFT_LIST_FILE"
}

ensure_sudo_group() {
  # Some environments may not have the 'sudo' group by default.
  if ! getent group sudo >/dev/null 2>&1; then
    warn "Group 'sudo' not found; creating it"
    groupadd sudo
  fi
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
}

get_os_id() {
  source /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
  printf "%s" "${ID:-unknown}"
}

get_os_version_id() {
  source /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
  printf "%s" "${VERSION_ID:-unknown}"
}

check_supported_os() {
  local os_id os_ver
  os_id="$(get_os_id)"
  os_ver="$(get_os_version_id)"

  case "$os_id:$os_ver" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13)
      log "Supported OS detected: ${os_id} ${os_ver}"
      ;;
    *)
      die "Unsupported OS: ${os_id} ${os_ver}. Supported targets: Ubuntu 22.04, Ubuntu 24.04, Debian 12, Debian 13."
      ;;
  esac
}

get_sshd_bin() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
    return 0
  fi

  local candidate
  for candidate in /usr/sbin/sshd /sbin/sshd; do
    if [[ -x "$candidate" ]]; then
      printf "%s" "$candidate"
      return 0
    fi
  done

  return 1
}

reload_ssh_service() {
  local unit
  for unit in ssh sshd; do
    if systemctl cat "${unit}.service" >/dev/null 2>&1; then
      systemctl reload "$unit" || systemctl restart "$unit" || return 1
      return 0
    fi
  done
  return 1
}

ssh_socket_activation_in_use() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl cat ssh.socket >/dev/null 2>&1 || return 1
  systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null
}

# socket activation 的监听端口由 systemd 管理。
sync_ssh_socket_port() {
  ssh_socket_activation_in_use || return 0

  if [[ "$SSH_PORT" == "22" ]]; then
    if [[ -f "$SSH_SOCKET_DROPIN_FILE" ]]; then
      rm -f "$SSH_SOCKET_DROPIN_FILE" || return 1
      systemctl daemon-reload || return 1
      systemctl restart ssh.socket || return 1
    fi
    return 0
  fi

  install -d -m 755 "$SSH_SOCKET_DROPIN_DIR" || return 1
  printf '# Managed by bootstrap-debian.sh\n[Socket]\nListenStream=\nListenStream=%s\n' \
    "$SSH_PORT" > "$SSH_SOCKET_DROPIN_FILE" || return 1
  chmod 644 "$SSH_SOCKET_DROPIN_FILE" || return 1
  systemctl daemon-reload || return 1
  systemctl restart ssh.socket || return 1
}

password_step_needed() {
  if ! id -u "$BOOTSTRAP_USER" >/dev/null 2>&1; then
    return 0
  fi

  local st
  st="$(passwd -S "$BOOTSTRAP_USER" 2>/dev/null | awk '{print $2}' || true)"

  [[ "$st" != "P" ]]
}

preflight_check() {
  check_supported_os
  load_package_list
  info "Bootstrap version: ${VERSION} (last modified: ${LAST_MODIFIED})"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required for public key validation."
  VALIDATED_PUBKEY="$(get_pubkey)" || die "Preflight failed: invalid SSH public key. No changes were made."
  [[ "$BOOTSTRAP_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ && "$BOOTSTRAP_USER" != root ]] \
    || die "BOOTSTRAP_USER must be a non-root login name."
  [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] || die "SSH_PORT must be between 1 and 65535."
  SSH_PORT=$((10#$SSH_PORT))
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT must be between 1 and 65535."
  local option
  for option in HARDEN_SSH DISABLE_SSH_PASSWORD DISABLE_ROOT_SSH DISABLE_ROOT_SSH_PASSWORD \
                CONFIGURE_SYSTEM_ZSHRC SET_ROOT_SHELL_ZSH FORCE_RUN; do
    [[ "${!option}" == 0 || "${!option}" == 1 ]] || die "$option must be 0 or 1."
  done
  info "Preflight: user=$BOOTSTRAP_USER, shell=$BOOTSTRAP_SHELL, SSH port=$SSH_PORT"

  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  info "Preflight: detected architecture: $arch"

  info "Preflight: system zshrc will be configured: CONFIGURE_SYSTEM_ZSHRC=$CONFIGURE_SYSTEM_ZSHRC"
  info "Preflight: root login shell will be changed to zsh: SET_ROOT_SHELL_ZSH=$SET_ROOT_SHELL_ZSH (ROOT_SHELL=$ROOT_SHELL)"
}

step_done() { [[ -f "${STATE_DIR}/$1.done" ]]; }
mark_done() { touch "${STATE_DIR}/$1.done"; }

# =========================
# Steps (幂等)
# =========================
step_apt_upgrade() {
  local step="apt_upgrade"
  step_done "$step" && { log "Skip: apt upgrade already done"; return; }

  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt upgrade -y
  mark_done "$step"
  log "Apt upgrade done"
}

step_apt_cleanup() {
  local step="apt_cleanup"
  step_done "$step" && { log "Skip: apt cleanup already done"; return; }

  apt autoremove --purge -y
  apt clean
  apt autoclean
  mark_done "$step"
  log "Apt cleanup done"
}

step_timezone() {
  local step="timezone"
  step_done "$step" && { log "Skip: timezone already set"; return; }

  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$BOOTSTRAP_TZ"
    mark_done "$step"
    log "Timezone set to $BOOTSTRAP_TZ"
  else
    warn "timedatectl not found; skip timezone"
    mark_done "$step"
  fi
}

step_ensure_sudo() {
  local step="ensure_sudo"
  step_done "$step" && { log "Skip: sudo already ensured"; return; }

  ensure_sudo_installed
  ensure_sudo_group

  mark_done "$step"
  log "sudo ensured"
}

step_install_pkgs() {
  local step="install_pkgs"
  # 不按旧标记跳过，确保清单改动可以生效。
  (( ${#CORE_PKGS[@]} > 0 )) || die "Package list was not loaded."

  export DEBIAN_FRONTEND=noninteractive

  apt install --no-remove -y "${CORE_PKGS[@]}"
  mark_done "$step"
  log "Packages installed"
}

# 仅接受单行 OpenSSH 公钥；完整内容由 ssh-keygen 校验。
get_pubkey() {
  local k=""
  if [[ -n "$BOOTSTRAP_PUBKEY" ]]; then
    k="$BOOTSTRAP_PUBKEY"
  elif [[ -n "$BOOTSTRAP_PUBKEY_FILE" && -r "$BOOTSTRAP_PUBKEY_FILE" ]]; then
    k="$(cat -- "$BOOTSTRAP_PUBKEY_FILE")" || return 1
  else
    die "Provide BOOTSTRAP_PUBKEY or a readable BOOTSTRAP_PUBKEY_FILE."
  fi
  k="${k%$'\r'}"
  [[ "$k" != *$'\n'* && "$k" != *$'\r'* ]] || die "Provide exactly one public key."
  [[ "$k" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:blank:]] ]] \
    || die "Unsupported OpenSSH public key type."
  ssh-keygen -lf <(printf '%s\n' "$k") >/dev/null 2>&1 || die "Invalid SSH public key."
  printf '%s' "$k"
}

step_create_user() {
  local step="create_user"
  # 用户和公钥每次都按实际状态检查。

  info "About to ensure user '$BOOTSTRAP_USER' exists and is in sudo group."
  info "This user will be able to SSH using the provided public key (public-key authentication)."
  info "Tip: DISABLE_SSH_PASSWORD=$DISABLE_SSH_PASSWORD controls whether SSH password login will be disabled later."

  # 1) 创建用户（幂等）
  if id -u "$BOOTSTRAP_USER" >/dev/null 2>&1; then
    log "User exists: $BOOTSTRAP_USER"
  else
    [[ -x "$BOOTSTRAP_SHELL" ]] || die "Configured BOOTSTRAP_SHELL not found or not executable: $BOOTSTRAP_SHELL"
    useradd -m -s "$BOOTSTRAP_SHELL" "$BOOTSTRAP_USER"
    log "User created: $BOOTSTRAP_USER"
  fi

  ensure_sudo_installed
  ensure_sudo_group
  # 2) sudo 权限（幂等）
  if id -nG "$BOOTSTRAP_USER" | tr ' ' '\n' | grep -qx sudo; then
    log "User already in sudo group"
  else
    usermod -aG sudo "$BOOTSTRAP_USER"
    log "Added user to sudo group"
  fi

  # 3) SSH key（幂等：存在就不重复追加同一行）
  local home_dir
  home_dir="$(getent passwd "$BOOTSTRAP_USER" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || die "Cannot resolve home directory for user: $BOOTSTRAP_USER"

  local ssh_dir="${home_dir}/.ssh"
  local auth_file="${ssh_dir}/authorized_keys"
  local pubkey
  pubkey="$VALIDATED_PUBKEY"
  [[ -n "$pubkey" ]] || die "No prevalidated public key available."

  # 已有用户的主组可能与用户名不同。
  local primary_group
  primary_group="$(id -gn "$BOOTSTRAP_USER")"
  install -d -m 700 -o "$BOOTSTRAP_USER" -g "$primary_group" "$ssh_dir"
  touch "$auth_file"
  chown "$BOOTSTRAP_USER:$primary_group" "$auth_file"
  chmod 600 "$auth_file"

  if grep -Fqx "$pubkey" "$auth_file"; then
    log "Public key already present in authorized_keys"
  else
    if [[ -s "$auth_file" && -n "$(tail -c1 "$auth_file")" ]]; then
      printf '\n' >> "$auth_file"
    fi
    printf "%s\n" "$pubkey" >> "$auth_file"
    log "Public key appended to authorized_keys"
  fi

  mark_done "$step"
  log "User bootstrap done"
}
step_set_password() {
  # 确保用户存在
  id -u "$BOOTSTRAP_USER" >/dev/null 2>&1 || die "User not found: $BOOTSTRAP_USER (run create_user step first)"

  # 判断当前密码状态：P=已设置；NP=未设置；L=锁定
  local st
  st="$(passwd -S "$BOOTSTRAP_USER" 2>/dev/null | awk '{print $2}' || true)"

  if [[ "$st" == "P" ]]; then
    log "Password already set for user: $BOOTSTRAP_USER"
    BOOTSTRAP_USER_PASSWORD=""
    return
  fi

  [[ -n "$BOOTSTRAP_USER_PASSWORD" ]] || die "Prevalidated password is empty; refusing to continue"

  info "Applying prevalidated password for user '$BOOTSTRAP_USER'."
  printf '%s:%s\n' "$BOOTSTRAP_USER" "$BOOTSTRAP_USER_PASSWORD" | chpasswd

  BOOTSTRAP_USER_PASSWORD=""
  log "Password set for user: $BOOTSTRAP_USER"
}

final_mark_done() {
  [[ -f "$DONE_FILE" ]] && { log "All bootstrap already completed (${DONE_FILE})"; return; }
  touch "$DONE_FILE"
  chmod 600 "$DONE_FILE"
  log "Bootstrap completed: ${DONE_FILE}"
}

step_shell_alias() {
  local step="shell_alias"
  step_done "$step" && { log "Skip: shell alias already configured"; return; }

  local user="$BOOTSTRAP_USER"
  local primary_group
  primary_group="$(id -gn "$user")"
  local home
  home="$(getent passwd "$user" | cut -d: -f6)"

  [[ -n "$home" ]] || die "Cannot determine home dir for $user"

  local alias_file="${home}/.shell_aliases"
  local alias_line="alias ll='ls -alF --color=auto'"

  # 创建 alias 文件（幂等）
  if [[ ! -f "$alias_file" ]]; then
    touch "$alias_file"
    chown "$user:$primary_group" "$alias_file"
    chmod 644 "$alias_file"
    log "Created $alias_file"
  fi

  # 写 alias（防重复）
  if grep -Fxq "$alias_line" "$alias_file"; then
    log "Alias ll already exists"
  else
    echo "$alias_line" >> "$alias_file"
    log "Alias ll added"
  fi

  # bash 加载（若不存在则创建）
  local bashrc="${home}/.bashrc"
  if [[ ! -f "$bashrc" ]]; then
    touch "$bashrc"
    chown "$user:$primary_group" "$bashrc"
    chmod 644 "$bashrc"
  fi
  if ! grep -Fq ".shell_aliases" "$bashrc"; then
    echo '[ -f ~/.shell_aliases ] && . ~/.shell_aliases' >> "$bashrc"
    log "Linked alias into .bashrc"
  fi

  # zsh 加载（若不存在则创建）
  local zshrc="${home}/.zshrc"
  if [[ ! -f "$zshrc" ]]; then
    touch "$zshrc"
    chown "$user:$primary_group" "$zshrc"
    chmod 644 "$zshrc"
  fi
  if ! grep -Fq ".shell_aliases" "$zshrc"; then
    echo '[ -f ~/.shell_aliases ] && source ~/.shell_aliases' >> "$zshrc"
    log "Linked alias into .zshrc"
  fi

  mark_done "$step"
}

step_configure_system_shell() {
  local step="configure_system_shell"
  [[ "$CONFIGURE_SYSTEM_ZSHRC" == "1" ]] || { warn "System zshrc disabled (CONFIGURE_SYSTEM_ZSHRC=0)"; return; }
  step_done "$step" && { log "Skip: system shell config already configured"; return; }

  # Ensure zsh exists
  command -v zsh >/dev/null 2>&1 || die "zsh not found (install_pkgs step should have installed it)"

  info "Configuring /etc/zsh/zshrc for prompt, colors, completion and common aliases (ll/la/l)."

  install -d -m 755 /etc/zsh
  cat >/etc/zsh/zshrc <<'EOF'
# /etc/zsh/zshrc - system-wide zsh config (managed by bootstrap-debian.sh)

# colors
autoload -Uz colors && colors
setopt PROMPT_SUBST

# completion
autoload -Uz compinit && compinit

# history
export HISTFILE=~/.zsh_history
export HISTSIZE=50000 SAVEHIST=50000
setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS HIST_IGNORE_SPACE EXTENDED_HISTORY

# common aliases (with color)
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'

# prompt: user@host:cwd + (# for root, % for user)
if [[ $EUID -eq 0 ]]; then
  PROMPT='%F{red}%n%f@%F{blue}%m%f:%F{yellow}%~%f %F{red}%#%f '
else
  PROMPT='%F{green}%n%f@%F{blue}%m%f:%F{yellow}%~%f %# '
fi
EOF

  chmod 644 /etc/zsh/zshrc

  # Also provide ll aliases for bash users via /etc/profile.d
  install -d -m 755 /etc/profile.d
  cat >/etc/profile.d/00-bootstrap-aliases.sh <<'EOF'
# managed by bootstrap-debian.sh
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
EOF
  chmod 644 /etc/profile.d/00-bootstrap-aliases.sh

  mark_done "$step"
  log "System shell experience configured (/etc/zsh/zshrc, /etc/profile.d/00-bootstrap-aliases.sh)"
}

step_root_shell_zsh() {
  local step="root_shell_zsh"
  [[ "$SET_ROOT_SHELL_ZSH" == "1" ]] || { warn "Root shell change disabled (SET_ROOT_SHELL_ZSH=0)"; return; }
  step_done "$step" && { log "Skip: root shell already processed"; return; }

  command -v zsh >/dev/null 2>&1 || die "zsh not found"

  # Ensure ROOT_SHELL exists
  [[ -x "$ROOT_SHELL" ]] || die "ROOT_SHELL not found or not executable: $ROOT_SHELL"

  local current_shell
  current_shell="$(getent passwd root | awk -F: '{print $7}')"

  if [[ "$current_shell" == "$ROOT_SHELL" ]]; then
    log "Root login shell already set to: $ROOT_SHELL"
    mark_done "$step"
    return
  fi

  warn "About to change root login shell from '$current_shell' to '$ROOT_SHELL'."
  warn "Tip: This affects interactive login. It does NOT affect non-interactive scripts using /bin/bash."

  # Prefer chsh, fallback to usermod
  if command -v chsh >/dev/null 2>&1; then
    chsh -s "$ROOT_SHELL" root
  else
    usermod -s "$ROOT_SHELL" root
  fi

  mark_done "$step"
  log "Root login shell changed to: $ROOT_SHELL (re-login required)"
}

# 检查普通用户及 root 在测试来源和当前连接来源下的最终认证策略。
verify_ssh_policy() {
  local sshd_bin="$1" user addr config value expected_root host
  local -a addresses=(127.0.0.1 192.0.2.1)
  [[ -z "${SSH_CONNECTION:-}" ]] || addresses+=("${SSH_CONNECTION%% *}")
  host="$(hostname)" || return 1
  expected_root=yes
  if [[ "$DISABLE_ROOT_SSH" == 1 ]]; then
    expected_root=no
  elif [[ "$DISABLE_ROOT_SSH_PASSWORD" == 1 ]]; then
    expected_root=prohibit-password
  fi

  for user in "$BOOTSTRAP_USER" root; do
    for addr in "${addresses[@]}"; do
      config="$("$sshd_bin" -T -C "user=$user,host=$host,addr=$addr")" || return 1
      value="$(awk '$1 == "pubkeyauthentication" {print $2}' <<< "$config")"
      [[ "$value" == yes ]] || { warn "Public-key authentication is disabled for $user@$addr"; return 1; }
      if [[ "$user" == "$BOOTSTRAP_USER" ]]; then
        value="$(awk '$1 == "authenticationmethods" {print $2}' <<< "$config")"
        [[ "$value" == any || "$value" == publickey ]] \
          || { warn "Conflicting AuthenticationMethods for $user@$addr"; return 1; }
        if [[ "$DISABLE_SSH_PASSWORD" == 1 ]]; then
          for value in passwordauthentication kbdinteractiveauthentication; do
            [[ "$(awk -v key="$value" '$1 == key {print $2}' <<< "$config")" == no ]] \
              || { warn "Conflicting $value for $user@$addr"; return 1; }
          done
        fi
      else
        value="$(awk '$1 == "permitrootlogin" {print $2}' <<< "$config")"
        [[ "$value" != without-password ]] || value=prohibit-password
        [[ "$value" == "$expected_root" ]] \
          || { warn "Conflicting PermitRootLogin for root@$addr"; return 1; }
        if [[ "$DISABLE_SSH_PASSWORD" == 1 && "$expected_root" == yes ]]; then
          [[ "$(awk '$1 == "passwordauthentication" {print $2}' <<< "$config")" == yes ]] \
            || { warn "Root password fallback is overridden for root@$addr"; return 1; }
        fi
      fi
    done
  done
}

# 在子 shell 内管理回滚，避免影响主流程的 trap。
step_harden_ssh() (
  [[ "$HARDEN_SSH" == 1 ]] || { warn "SSH hardening disabled (HARDEN_SSH=0)"; return; }
  id -u "$BOOTSTRAP_USER" >/dev/null 2>&1 || die "User not found: $BOOTSTRAP_USER"
  dropin_dir=/etc/ssh/sshd_config.d
  committed=0 staged=0 runtime_touched=0 socket_in_use=0
  sshd_bin="$(get_sshd_bin)" || die "sshd binary not found."
  dropin_file="$dropin_dir/10-bootstrap.conf"
  legacy_file="$dropin_dir/99-bootstrap.conf"
  install -d -m 755 /run/sshd "$dropin_dir"
  "$sshd_bin" -t || die "Existing SSH configuration is invalid; no SSH configuration was changed."
  workdir="$(mktemp -d "$dropin_dir/.bootstrap.XXXXXX")"

  cleanup_ssh_change() {
    local rc=$? failed=0
    trap - EXIT
    if [[ "$committed" == 0 && "$staged" == 1 ]]; then
      warn "SSH configuration failed; restoring previous configuration."
      if [[ -e "$workdir/original" ]]; then
        mv -f "$workdir/original" "$dropin_file" || failed=1
      else
        rm -f "$dropin_file" || failed=1
      fi
      if [[ -e "$workdir/legacy" ]]; then
        mv -f "$workdir/legacy" "$legacy_file" || failed=1
      fi
      if [[ -e "$workdir/socket" ]]; then
        mv -f "$workdir/socket" "$SSH_SOCKET_DROPIN_FILE" || failed=1
      else
        rm -f "$SSH_SOCKET_DROPIN_FILE" || failed=1
      fi
      rm -f "$STATE_DIR/harden_ssh.done" || failed=1
      if [[ "$runtime_touched" == 1 ]]; then
        if [[ "$socket_in_use" == 1 ]]; then
          systemctl daemon-reload || failed=1
          systemctl restart ssh.socket || failed=1
        fi
        reload_ssh_service || failed=1
      fi
    fi
    if [[ "$failed" == 1 ]]; then
      warn "Rollback was incomplete; inspect SSH services and backup directory: $workdir"
    else
      rm -rf -- "$workdir"
    fi
    exit "$rc"
  }
  trap cleanup_ssh_change EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # 同时保存旧文件与 socket 配置，失败时恢复。
  local file
  for file in "$dropin_file" "$legacy_file" "$SSH_SOCKET_DROPIN_FILE"; do
    [[ ! -L "$file" ]] || die "Refusing to replace symlink: $file"
  done
  [[ ! -f "$dropin_file" ]] || cp -p "$dropin_file" "$workdir/original"
  [[ ! -f "$legacy_file" ]] || cp -p "$legacy_file" "$workdir/legacy"
  [[ ! -f "$SSH_SOCKET_DROPIN_FILE" ]] || cp -p "$SSH_SOCKET_DROPIN_FILE" "$workdir/socket"
  if ssh_socket_activation_in_use; then socket_in_use=1; fi

  # 生成独立配置，避免修改主配置文件。
  {
    echo "# Managed by bootstrap-debian.sh"
    echo "Port ${SSH_PORT}"
    echo "PubkeyAuthentication yes"

    # Password auth policy (global)
    if [[ "$DISABLE_SSH_PASSWORD" == "1" ]]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "ChallengeResponseAuthentication no"
    fi

    # Root login policy
    if [[ "$DISABLE_ROOT_SSH" == "1" ]]; then
      echo "PermitRootLogin no"
    else
      if [[ "$DISABLE_ROOT_SSH_PASSWORD" == "1" ]]; then
        # allow root via key only
        echo "PermitRootLogin prohibit-password"
      else
        # allow root password login as a fallback
        echo "PermitRootLogin yes"
      fi
    fi

    # AllowUsers: by default allow both the bootstrap user and root (fallback)
    if [[ "$DISABLE_ROOT_SSH" == "1" ]]; then
      echo "AllowUsers ${BOOTSTRAP_USER}"
    else
      echo "AllowUsers ${BOOTSTRAP_USER} root"
    fi

    # 为 root 单独保留密码兜底。
    if [[ "$DISABLE_SSH_PASSWORD" == "1" && "$DISABLE_ROOT_SSH" != "1" && "$DISABLE_ROOT_SSH_PASSWORD" != "1" ]]; then
      echo "Match User root"
      echo "  PasswordAuthentication yes"
      echo "  KbdInteractiveAuthentication yes"
      echo "  ChallengeResponseAuthentication yes"
    fi
  } > "$workdir/candidate"

  chmod 644 "$workdir/candidate"
  staged=1
  mv -f "$workdir/candidate" "$dropin_file"
  rm -f "$legacy_file"
  "$sshd_bin" -t || die "New SSH configuration is invalid."
  verify_ssh_policy "$sshd_bin" || die "SSH policy is overridden by other configuration."

  runtime_touched=1
  sync_ssh_socket_port || die "Unable to update ssh.socket."
  reload_ssh_service || die "Unable to reload/restart SSH service."
  mark_done harden_ssh
  committed=1
  log "SSH configuration validated and applied."
)

main() {
  case "${1:-}" in
    -h|--help)
      printf 'Usage: bash bootstrap-debian.sh [--check|--packages-only]\nPackage list: %s\n' "$SOFT_LIST_FILE"
      return 0
      ;;
    --check)
      [[ $# == 1 ]] || die "--check takes no arguments."
      require_root
      preflight_check
      log "Preflight passed; no system changes were made."
      return 0
      ;;
    --packages-only)
      [[ $# == 1 ]] || die "--packages-only takes no arguments."
      require_root
      check_supported_os
      load_package_list
      ensure_state_dir
      export DEBIAN_FRONTEND=noninteractive
      apt update
      step_install_pkgs
      return 0
      ;;
    '') ;;
    *) die "Unknown option: $1" ;;
  esac
  require_root
  preflight_check
  if [[ -f "$DONE_FILE" && "$FORCE_RUN" != "1" ]]; then
    warn "Already bootstrapped (found $DONE_FILE). Set FORCE_RUN=1 to re-run."
    exit 0
  fi

  if password_step_needed; then
    collect_bootstrap_password
  else
    info "Password step does not require input for this run."
  fi

  ensure_state_dir

  info "Step 1/11: apt update & upgrade"
  step_apt_upgrade

  info "Step 2/11: apt cleanup"
  step_apt_cleanup

  info "Step 3/11: set timezone ($BOOTSTRAP_TZ)"
  step_timezone

  info "Step 4/11: install packages from $SOFT_LIST_FILE"
  step_install_pkgs

  info "Step 5/11: ensure sudo is available"
  step_ensure_sudo

  info "Step 6/11: create user, grant sudo, install SSH public key"
  step_create_user

  info "Step 7/11: apply prevalidated password for user"
  step_set_password

  info "Step 8/11: configure shell aliases"
  step_shell_alias

  info "Step 9/11: configure system-wide shell experience (zsh prompt/colors/completion + aliases)"
  step_configure_system_shell

  info "Step 10/11: optional change root login shell to zsh (SET_ROOT_SHELL_ZSH=$SET_ROOT_SHELL_ZSH)"
  step_root_shell_zsh

  info "Step 11/11: harden sshd (HARDEN_SSH=$HARDEN_SSH)"
  step_harden_ssh

  final_mark_done
  log "All steps finished. Test SSH in a NEW terminal/session before closing the current root session."
}

main "$@"
