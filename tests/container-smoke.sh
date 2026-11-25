#!/usr/bin/env bash
# container-smoke.sh — 仅在一次性容器内运行的冒烟检查（CI 与本地 Docker 共用）。
# 用法：docker run --rm -v "$PWD:/src:ro" debian:13 bash /src/tests/container-smoke.sh
# 检查：只读预检、软件清单在目标发行版可解析（apt 模拟安装）、各组件帮助入口。
# 会在容器内安装 openssh-client；拒绝在非容器环境运行，不执行任何初始化步骤。
set -Eeuo pipefail

SRC="${SRC:-/src}"

if [[ ! -f /.dockerenv && -z "${container:-}" && "${SMOKE_IN_CONTAINER:-0}" != 1 ]]; then
  echo '[ERROR] container-smoke.sh 只能在一次性容器中运行。' >&2
  exit 1
fi

. /etc/os-release
echo "== ${PRETTY_NAME}"

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update
apt-get -qq install -y --no-install-recommends openssh-client >/dev/null

echo '== 只读预检（bootstrap-debian.sh --check）'
work="$(mktemp -d)"
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
BOOTSTRAP_PUBKEY_FILE="$work/key.pub" bash "$SRC/bootstrap-debian.sh" --check

echo '== 软件清单解析（apt-get -s，不实际安装）'
packages=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"; line="${line%%#*}"
  read -r line <<< "$line" || true
  [[ -n "$line" ]] || continue
  # 与 bootstrap-debian.sh 一致：新系统中 ping 解析为 iputils-ping。
  [[ "$line" != ping ]] || line=iputils-ping
  packages+=("$line")
done < "$SRC/soft-list"
apt-get -s install --no-remove -y "${packages[@]}" > "$work/simulate.log"
echo "OK：${#packages[@]} 个条目均可安装"

echo '== 组件帮助入口'
bash "$SRC/server-init.sh" --help >/dev/null
bash "$SRC/server-init.sh" --version
bash "$SRC/bootstrap-debian.sh" --help >/dev/null
bash "$SRC/setup-swap.sh" --version
bash "$SRC/enable-bbr.sh" --version
bash "$SRC/ufw-manager.sh" version
bash "$SRC/server-security-audit.sh" --version
bash "$SRC/ipv6-manager.sh" version

rm -rf -- "$work"
echo "== 通过：${PRETTY_NAME}"
