#!/usr/bin/env bash
# install-docker.sh — 独立安装 Docker Engine、Buildx 和 Compose。
# Version: 1.5.2 | Updated: 2026-11-05
# 用法：bash install-docker.sh [-u USER] [-S] [-L]
# -u：加入 docker 组；-S：跳过 hello-world；-L：仅在 daemon.json 不存在时配置日志轮转。
# 日志参数：DOCKER_LOG_MAX_SIZE=10m，DOCKER_LOG_MAX_FILE=3；必须为正数，不覆盖已有配置。
# 使用官方仓库，保留已有数据；docker 组具有接近 root 的权限。
# Docker 发布端口需单独检查，不能仅依赖 UFW。请保存文件后运行。

set -euo pipefail
trap 'echo -e "\033[1;31m[ERR ] 发生错误：行号 $LINENO\033[0m" >&2' ERR

info()  { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()   { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; exit 1; }

is_tty() { [[ -t 0 && -t 1 ]]; }

ask_yes_no() {
  # Usage: ask_yes_no "question" "default"(Y/N)
  local q="$1"; local def="${2:-Y}"; local ans
  while true; do
    if [[ "$def" == "Y" ]]; then
      read -r -p "$q [Y/n]: " ans || return 1
      ans="${ans:-Y}"
    else
      read -r -p "$q [y/N]: " ans || return 1
      ans="${ans:-N}"
    fi
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "请输入 y 或 n" ;;
    esac
  done
}

default_invoking_user() {
  # Prefer the original user when script re-exec'd via sudo.
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
    return
  fi
  logname 2>/dev/null || true
}

cleanup_hello_world_images() {
  # Remove hello-world images only. Avoid global dangling cleanup.
  # This is intentionally conservative (no prune / no dangling removal).
  local ids

  # Remove common tags (ignore errors)
  docker image rm -f hello-world:latest hello-world >/dev/null 2>&1 || true

  # Remove by repository match (if any remain)
  ids="$(docker images --format '{{.Repository}} {{.ID}}' 2>/dev/null | awk '$1=="hello-world"{print $2}' | sort -u || true)"
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker image rm -f $ids >/dev/null 2>&1 || true
  fi
}

add_to_docker_group() {
  # Usage: add_to_docker_group USER
  local u="$1"
  if id "$u" >/dev/null 2>&1; then
    info "将用户 [$u] 加入 docker 组（如不存在将创建）..."
    warn "安全提示：加入 docker 组相当于授予接近 root 的权限（可访问 /var/run/docker.sock）。仅对可信运维用户启用。"
    getent group docker >/dev/null 2>&1 || groupadd docker
    usermod -aG docker "$u"
    info "完成。请让 [$u] 重新登录或执行：newgrp docker"
  else
    warn "用户 [$u] 不存在，跳过加入 docker 组。"
  fi
}

configure_log_rotation() {
  # 仅在 daemon.json 不存在时写入；已存在则跳过，绝不覆盖用户配置。
  local f="/etc/docker/daemon.json"
  local max_size="${DOCKER_LOG_MAX_SIZE:-10m}"
  local max_file="${DOCKER_LOG_MAX_FILE:-3}"

  [[ "$max_size" =~ ^[0-9]*[1-9][0-9]*[kKmMgG]?$ ]] || die "DOCKER_LOG_MAX_SIZE 必须为正数（示例：10m）：${max_size}"
  [[ "$max_file" =~ ^[0-9]*[1-9][0-9]*$ ]] || die "DOCKER_LOG_MAX_FILE 必须为正整数：${max_file}"

  if [[ -f "$f" ]]; then
    warn "已存在 ${f}，跳过日志轮转配置（不会覆盖）。"
    return 0
  fi

  info "写入日志轮转配置 ${f}（max-size=${max_size}, max-file=${max_file}）..."
  install -d -m 0755 /etc/docker
  cat > "$f" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${max_size}",
    "max-file": "${max_file}"
  }
}
EOF
  chmod 644 "$f"
  DAEMON_JSON_CREATED="1"
}

# 连接正在运行的 systemd 管理器，而不是只检查客户端版本。
systemd_is_running() {
  command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1
}

ADD_USER=""
SKIP_HELLO="0"
ENABLE_LOG_ROTATION="0"
DAEMON_JSON_CREATED="0"

while getopts ":u:SL" opt; do
  case "$opt" in
    u) ADD_USER="$OPTARG" ;;
    S) SKIP_HELLO="1" ;;
    L) ENABLE_LOG_ROTATION="1" ;;
    *) die "用法: $0 [-u USER] [-S] [-L]" ;;
  esac
done

# 提权
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    [[ -f "$0" ]] || die "无法重新执行：脚本需保存为文件后运行（不支持 curl | bash），或直接以 root 运行。"
    info "使用 sudo 重新执行脚本..."
    exec sudo bash "$0" "$@"
  else
    die "请以 root 运行或先安装 sudo。"
  fi
fi

export DEBIAN_FRONTEND=noninteractive

# 识别系统
[[ -r /etc/os-release ]] || die "未找到 /etc/os-release。"
. /etc/os-release
ID_LC="${ID,,}"
if [[ "$ID_LC" == "ubuntu" ]]; then
  CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
else
  CODENAME="${VERSION_CODENAME:-}"
fi

if [[ -z "${CODENAME}" ]]; then
  apt-get update -y
  apt-get install -y --no-install-recommends lsb-release
  CODENAME="$(lsb_release -cs || true)"
fi
[[ -n "$CODENAME" ]] || die "无法获取发行版代号（UBUNTU_CODENAME/VERSION_CODENAME/lsb_release）。"

case "$ID_LC" in
  debian) REPO_BASE="https://download.docker.com/linux/debian" ;;
  ubuntu) REPO_BASE="https://download.docker.com/linux/ubuntu" ;;
  *) die "不支持的系统：$ID_LC（仅 Debian/Ubuntu）" ;;
esac

ARCH="$(dpkg --print-architecture)"
info "系统：$ID_LC；代号：$CODENAME；架构：$ARCH"

# 依赖（先装依赖，便于后续探测仓库；此步不改动 Docker 相关包）
info "安装依赖（ca-certificates, curl）..."
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl

# 提前探测官方仓库是否支持当前发行版代号（在卸载任何包之前，尽早失败）
info "探测 Docker 官方仓库是否支持 ${ID_LC}/${CODENAME}..."
if ! curl -fsSL --max-time 20 -o /dev/null "${REPO_BASE}/dists/${CODENAME}/Release"; then
  die "无法访问 ${REPO_BASE}/dists/${CODENAME}/Release：可能是 Docker 官方暂未支持该发行版（${ID_LC} ${CODENAME}），或网络受限。未对系统做任何改动。"
fi

# 记录安装前 docker 是否在运行（用于决定是否需要重启以应用 daemon.json）
DOCKER_WAS_ACTIVE="0"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
  DOCKER_WAS_ACTIVE="1"
fi

# 卸载冲突包（幂等）：仅处理官方文档列出的非官方/冲突包，不动 docker-ce / containerd.io 等官方包
CONFLICT_PKGS=(
  docker docker-engine docker.io docker-doc docker-compose docker-compose-v2
  docker-buildx podman-docker containerd runc
)
TO_REMOVE=()
for p in "${CONFLICT_PKGS[@]}"; do
  if dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii'; then
    TO_REMOVE+=("$p")
  fi
done
if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
  warn "检测到冲突/非官方包，将卸载：${TO_REMOVE[*]}（/var/lib/docker 数据不会被删除；使用这些包运行的容器会中断）"
  apt-get remove -y "${TO_REMOVE[@]}"
else
  info "未发现冲突/非官方 Docker 包。"
fi

# Keyring
KEYDIR="/etc/apt/keyrings"
KEYFILE="${KEYDIR}/docker.asc"
KEYTMP="${KEYFILE}.tmp"
install -m 0755 -d "$KEYDIR"
info "导入 Docker 官方仓库 key 到 ${KEYFILE}（原子写入）..."
rm -f "$KEYTMP"
curl -fsSL "${REPO_BASE}/gpg" -o "$KEYTMP"
[[ -s "$KEYTMP" ]] || die "下载的 GPG key 为空：${REPO_BASE}/gpg"
chmod a+r "$KEYTMP"
mv -f "$KEYTMP" "$KEYFILE"

# 清理旧源/旧 key，避免与新官方 deb822 写法冲突
OLD_LIST_FILE="/etc/apt/sources.list.d/docker.list"
OLD_KEYFILE="${KEYDIR}/docker.gpg"
if [[ -f "$OLD_LIST_FILE" ]]; then
  info "检测到旧版 Docker 源 ${OLD_LIST_FILE}，将其移除以避免冲突..."
  rm -f "$OLD_LIST_FILE"
fi
if [[ -f "$OLD_KEYFILE" ]]; then
  info "检测到旧版 Docker key ${OLD_KEYFILE}，将其移除以避免混用..."
  rm -f "$OLD_KEYFILE"
fi

# 源（采用 deb822 官方推荐格式）
LIST_FILE="/etc/apt/sources.list.d/docker.sources"
info "写入 Docker 源到 ${LIST_FILE}（deb822）..."
cat > "$LIST_FILE" <<EOF
Types: deb
URIs: ${REPO_BASE}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: ${KEYFILE}
EOF

# 可选：日志轮转（先于安装写入，全新安装时 docker 首次启动即生效）
if [[ "$ENABLE_LOG_ROTATION" == "1" ]]; then
  configure_log_rotation
fi

# 安装核心组件（与官方一致，不使用 --no-install-recommends）
info "安装 Docker Engine / CLI / containerd / buildx / compose 插件..."
apt-get update -y
apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 服务管理：兼容无 systemd 的环境
if systemd_is_running; then
  info "启用并启动 docker 服务（systemd）..."
  systemctl enable --now docker
  systemctl enable --now containerd
  # 仅当本次新建了 daemon.json 且 docker 在安装前已在运行时才需要重启以应用配置
  if [[ "$DAEMON_JSON_CREATED" == "1" && "$DOCKER_WAS_ACTIVE" == "1" ]]; then
    warn "新建了 daemon.json 且 docker 此前已在运行，重启 docker 以应用配置（会短暂中断容器）..."
    systemctl restart docker
  fi
elif command -v service >/dev/null 2>&1; then
  warn "未检测到 systemd，使用 service 启动 docker（环境可能是容器/WSL）..."
  service docker start || die "无法通过 service 启动 Docker。"
else
  warn "未检测到 systemd/service。请在此环境中手工管理 dockerd。"
fi

# 版本信息
if command -v docker >/dev/null 2>&1; then
  info "Docker 版本：$(docker --version 2>/dev/null || echo N/A)"
else
  die "docker 未在 PATH 中，安装可能未成功。"
fi
if docker compose version >/dev/null 2>&1; then
  info "Compose 插件：$(docker compose version)"
else
  warn "未检测到 docker compose 插件版本（非致命）。"
fi

# 验证
if [[ "$SKIP_HELLO" != "1" ]]; then
  info "运行 hello-world 验证镜像..."
  if ! docker run --pull=missing --rm hello-world >/dev/null 2>&1; then
    warn "hello-world 拉取/运行失败，可能是镜像网络受限；Docker 已安装。"
  else
    info "hello-world 运行成功。"
  fi

  if is_tty; then
    if ask_yes_no "是否清理 hello-world 镜像（避免残留）？" "Y"; then
      info "清理 hello-world 镜像..."
      cleanup_hello_world_images
      info "hello-world 镜像清理完成。"
    else
      info "已保留 hello-world 镜像。"
    fi
  fi
else
  info "已按参数跳过 hello-world 验证。"
fi

# 加组（免 sudo）
if [[ -n "$ADD_USER" ]]; then
  add_to_docker_group "$ADD_USER"
else
  if is_tty; then
    local_default_user="$(default_invoking_user)"
    local_default_user="${local_default_user:-${USER:-}}"

    if [[ -z "$local_default_user" || "$local_default_user" == "root" ]]; then
      # 默认用户为空或 root：root 无需加组，改为让用户手动指定
      read -r -p "如需让某个普通用户免 sudo 使用 docker，请输入用户名（直接回车跳过）: " _u || _u=""
      if [[ -n "${_u:-}" ]]; then
        add_to_docker_group "$_u"
      else
        info "已跳过加入 docker 组。"
      fi
    elif ask_yes_no "是否将用户 [$local_default_user] 加入 docker 组以免 sudo 使用 docker？" "Y"; then
      read -r -p "请输入要加入 docker 组的用户名（直接回车使用默认：$local_default_user）: " _u || _u=""
      add_to_docker_group "${_u:-$local_default_user}"
    else
      info "已跳过加入 docker 组。"
    fi
  else
    info "如需免 sudo 使用 docker：sudo usermod -aG docker \$USER && newgrp docker"
  fi
fi

info "🎉 Docker 安装完成。"
