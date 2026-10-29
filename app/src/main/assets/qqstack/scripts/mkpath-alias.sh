#!/bin/bash
# 建"路径别名"：容器内 /proc/<pid>/maps 显示的是宿主绝对路径
# （如 /data/data/com.termux/.../installed-rootfs/ubuntu/opt/QQ/qq），
# 而容器里看到的是 /opt/QQ/qq。hook 按 maps 里的路径打开文件会失败，
# 所以要在容器里造一棵同名的软链接树指回真实目录。
#
# 用法：bash scripts/mkpath-alias.sh [--probe]
#   --probe  只探测并打印 HOST_ROOT，不建链接（幂等，安全）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"

probe_root() {
  # 1) deploy.env 里写死的
  [ -n "${HOST_ROOT:-}" ] && [ -d "$HOST_ROOT" ] && { echo "$HOST_ROOT"; return 0; }
  # 2) 从 QQ 进程的 maps 里反推（最准：那是 /proc/maps 里真实显示的前缀）
  local q p
  q=$(pgrep -x qq 2>/dev/null | head -1)
  if [ -n "$q" ]; then
    p=$(grep -a -m1 -o '/data/data/[^ ]*/opt/QQ/qq' "/proc/$q/maps" 2>/dev/null | head -1)
    [ -n "$p" ] && { echo "${p%/opt/QQ/qq}"; return 0; }
  fi
  # 3) mounts 里找 rootfs 挂载点
  p=$(grep -o '/data/data/[^ ]*/files/rootfs' /proc/self/mounts 2>/dev/null | head -1)
  [ -n "$p" ] && { echo "$p"; return 0; }
  # 4) 兜底：本 App 的标准路径 / proot-distro 的标准路径
  for c in /data/data/com.yuanbao.qqbot/files/rootfs \
           /data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu; do
    [ -d "$c" ] && { echo "$c"; return 0; }
  done
  echo "/data/data/com.yuanbao.qqbot/files/rootfs"
}

ROOT="$(probe_root)"
if [ "${1:-}" = "--probe" ]; then echo "$ROOT"; exit 0; fi

echo "[alias] 宿主 rootfs 前缀 = $ROOT"
mkdir -p "$ROOT" 2>/dev/null || { echo "[alias] 无法创建 $ROOT（容器内路径不可写？）"; exit 1; }

# 注意：不链 /proc /dev /sys，会把容器里的东西指坏
for d in /bin /sbin /etc /lib /lib64 /opt /root /tmp /usr /var /home /sdcard; do
  [ -e "$d" ] || continue
  ln -sfn "$d" "$ROOT/" 2>/dev/null
done
ln -sfn "${AGENT_DIR:-/opt/qqagent}" "$ROOT/opt/qqagent" 2>/dev/null

echo "[alias] 已建别名，抽查："
for x in opt/QQ/qq opt/snowluma/index.mjs opt/qqstack/libslhook.so; do
  if [ -e "$ROOT/$x" ]; then echo "  ✓ $ROOT/$x"
  else echo "  · $ROOT/$x （不存在，QQ/SnowLuma 还没装）"; fi
done
