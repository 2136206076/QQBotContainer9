#!/bin/bash
# 生成 /proc/locks 的替身文件（供 patch/patch_snowluma.py 注入的兜底读取）
# 做法：扫 /proc 找 QQ 主进程（进程名 qq、命令行无 --type=），按 /proc/locks 的格式写一行
# 用法：bash scripts/mkfake-locks.sh          # 生成一次
#       bash scripts/mkfake-locks.sh --loop   # 每 10 秒刷新（QQ 起来后跑）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
OUT=${SNOWLUMA_FAKE_LOCKS:-/opt/qqstack/fake-locks}
mkdir -p "$(dirname "$OUT")"

gen() {
  local pids n=1 tmp="$OUT.tmp"
  : >"$tmp"
  pids=$(pgrep -x qq 2>/dev/null)
  [ -z "$pids" ] && { rm -f "$tmp"; return 1; }
  for pid in $pids; do
    # 只要主进程：命令行里没有 --type=
    grep -qa -- '--type=' "/proc/$pid/cmdline" 2>/dev/null && continue
    # 找一个它打开的可写普通文件当作"被锁文件"，取 inode
    local inode dev
    read -r dev inode < <(for fd in /proc/$pid/fd/*; do
        t=$(readlink "$fd" 2>/dev/null) || continue
        case "$t" in /root/.config/QQ/*|/opt/QQ/*) [ -f "$t" ] && stat -L -c '%d %i' "$t" 2>/dev/null && break;; esac
      done)
    dev=${dev:-64769}; inode=${inode:-1}
    local maj=$((dev/256)) min=$((dev%256))
    printf '%d: FLOCK  ADVISORY  WRITE %d %02x:%02x:%d 0 EOF\n' "$n" "$pid" "$maj" "$min" "$inode" >>"$tmp"
    n=$((n+1))
  done
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$OUT"
}

if [ "${1:-}" = "--loop" ]; then
  while :; do gen; sleep 10; done
else
  if gen; then echo "[fake-locks] 已更新 $OUT：$(head -2 "$OUT" | tr '\n' '|')"
  else echo "[fake-locks] QQ 没在跑，跳过"; fi
fi
