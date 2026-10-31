#!/bin/bash
# 在 proot Ubuntu 里执行一次：装依赖 + 建目录 + 编 hook 载入器
# 用法：bash scripts/proot-bootstrap.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
export DEBIAN_FRONTEND=noninteractive
say(){ echo; echo "===== $* ====="; }
fail=0

say "0. 确认架构"
uname -m | grep -qE 'aarch64|arm64' || echo "  ⚠ 非 arm64：$(uname -m)，QQ/SnowLuma 要换对应架构的包"

say "1. 系统包"
write_ports() {
  cat >/etc/apt/sources.list <<'EOS'
deb http://ports.ubuntu.com/ubuntu-ports noble main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe multiverse
EOS
}
write_tuna() {
  cat >/etc/apt/sources.list <<'EOS'
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports noble main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports noble-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports noble-security main restricted universe multiverse
EOS
}

if ! apt-get update -qq 2>/dev/null; then
  echo "  ⚠ 当前 apt 源不通，换官方 ports 源重试"
  write_ports
  if ! apt-get update -qq 2>/dev/null; then
    echo "  ⚠ 官方 ports 不通，再试清华 ubuntu-ports"
    write_tuna
    apt-get update -qq || echo "  ⚠ apt update 仍失败，检查网络"
  fi
fi

apt-get install -y --no-install-recommends \
  ca-certificates curl wget xz-utils unzip git gnupg \
  procps psmisc dbus-x11 xdotool \
  xvfb fluxbox x11vnc novnc websockify \
  libgbm1 libnss3 libasound2t64 libgtk-3-0t64 libxshmfence1 libxdamage1 \
  libdrm2 libxkbcommon0 libxkbcommon-x11-0 fontconfig fonts-noto-cjk \
  imagemagick gifsicle python3 build-essential \
  || fail=1
command -v curl >/dev/null && command -v python3 >/dev/null && command -v gcc >/dev/null \
  && echo "  ✓ 系统包完成" \
  || { echo "  ✗ 关键包缺失（curl/python3/gcc）"; fail=1; }

say "2. Node（Ubuntu 24.04 的 apt 源是 18.x，QQ Agent 要 ≥${NODE_MIN:-22.16.0}）"
# QQ Agent 的硬门槛是 22.16.0，不是 22：它用 Node 内置 SQLite，而 FTS5 与
# DatabaseSync.isTransaction 这两个能力都是 22.16.0 才编进 Node 的
# （22.13~22.15 会得到 "no such module: fts5"，数据库建不起来）。
# 所以不能再用 ^v(2[0-9]|3[0-9]) 这种正则 —— v22.5 也能过，但照样起不来。
# 用 sort -V 做真正的版本比较：cur >= min 时排序后第一行是 min。
node_min_ok() {
  local cur="${2:-}"
  [ -n "$cur" ] || cur=$(node -v 2>/dev/null | sed -n 's/^v\([0-9][0-9.]*\).*/\1/p')
  [ -n "$cur" ] || return 1
  [ "$(printf '%s\n%s\n' "${NODE_MIN:-22.16.0}" "$cur" | sort -V | head -n1)" = "${NODE_MIN:-22.16.0}" ]
}
install_node() {
  # $1 = NodeSource 通道（22.x / 24.x）
  mkdir -p /etc/apt/keyrings
  if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; then
    # 说明：NodeSource 的 node_22.x 是滚动通道，给的是当前最新的 22.x（≥22.16.0），
    # 能满足 QQ Agent；万一哪天这个通道滞后了，下面还有 24.x 兜底。
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$1 nodistro main" \
      >/etc/apt/sources.list.d/nodesource.list
    apt-get update -qq && apt-get install -y nodejs
  fi
}
if node_min_ok; then
  echo "  ✓ 已装 $(node -v)（≥${NODE_MIN:-22.16.0}，满足 QQ Agent）"
else
  echo "  · 当前 $(node -v 2>/dev/null || echo 未安装)，低于 ${NODE_MIN:-22.16.0}，装 NodeSource node_22.x"
  install_node 22.x
  if ! node_min_ok; then
    echo "  · 22.x 通道给的版本仍不满足，改试 NodeSource node_24.x（LTS）"
    install_node 24.x
  fi
  if node_min_ok; then
    echo "  ✓ $(node -v)"
  else
    echo "  ✗ Node ≥${NODE_MIN:-22.16.0} 安装失败（QQ Agent 会起不来：no such module: fts5）"
    fail=1
  fi
fi

say "3. 目录"
mkdir -p "${STACK_DIR:-/opt/qqstack}/run" /tmp/.X11-unix
if [ -d "$HERE/../bin" ]; then cp -f "$HERE"/../bin/* "${STACK_DIR:-/opt/qqstack}/" 2>/dev/null; fi
ls -l "${STACK_DIR:-/opt/qqstack}/"

say "4. 编译 hook 载入器 libslhook.so"
if command -v gcc >/dev/null 2>&1; then
  SRC="$HERE/../bin/slhook.c"
  [ -f "$SRC" ] || SRC="${STACK_DIR:-/opt/qqstack}/slhook.c"
  if [ -f "$SRC" ]; then
    gcc -shared -fPIC -O2 -o "${STACK_DIR:-/opt/qqstack}/libslhook.so" "$SRC" -ldl -lpthread \
      && echo "  ✓ 已生成 ${STACK_DIR:-/opt/qqstack}/libslhook.so" \
      || { echo "  ✗ 编译失败，看上面的报错"; fail=1; }
  else
    echo "  ⚠ 没找到 slhook.c（应放在 bin/ 目录）"
    fail=1
  fi
else
  echo "  ⚠ 没有 gcc，先 apt install build-essential"
  fail=1
fi

say "5. 路径别名 + 冻结热更新"
bash "$HERE/mkpath-alias.sh" | sed 's/^/  /'
bash "$HERE/freeze-hotupdate.sh" | sed 's/^/  /'

say "6. VNC 密码（扫码用，默认 12345678，可在 deploy.env 改 VNC_PASS）"
if [ ! -f "${STACK_DIR:-/opt/qqstack}/vncpasswd" ] || [ -n "${VNC_PASS:-}" ]; then
  x11vnc -storepasswd "${VNC_PASS:-12345678}" "${STACK_DIR:-/opt/qqstack}/vncpasswd" \
    && echo "  ✓ 密码文件已生成" || echo "  ⚠ 生成失败"
else
  echo "  ✓ 已存在"
fi

say "6.5 导出 resident dispatch 载荷（hook 的磁盘兜底要用）"
# proot 下 memfd 版 dlopen 加载不了，slhook.c 会换成磁盘路径加载，而那个磁盘 .so
# 官方包不带，得从 SnowLuma 主库内嵌的 ELF 载荷里抠出来（tools/extract-resident-dispatch.py）。
# 顺序说明：本脚本在 App 的 [4/9] 执行，SnowLuma 通常 [6/9] 才装 —— 所以这里
# 「源文件不在」是正常情况，只跳过、不算失败，真正生效的位置是 start-all.sh / slhook-diag.sh。
EXTRACT_PY="$HERE/../tools/extract-resident-dispatch.py"
SRC_SO="${HOOK_SO:-${SNOWLUMA_DIR:-/opt/snowluma}/native/snowluma-linux-arm64.so}"
DST_SO="${RESIDENT_SO:-${STACK_DIR:-/opt/qqstack}/libsnowluma_linux_resident_dispatch.so}"
if [ ! -f "$SRC_SO" ]; then
  echo "  · SnowLuma 主库还没装（$SRC_SO），跳过 —— 稍后 patch/start-all 会自动补做"
elif [ ! -f "$EXTRACT_PY" ]; then
  echo "  ⚠ 找不到导出脚本 $EXTRACT_PY，跳过"
elif command -v python3 >/dev/null 2>&1; then
  python3 "$EXTRACT_PY" --source "$SRC_SO" --target "$DST_SO" 2>&1 | sed 's/^/  /'
  extract_rc="${PIPESTATUS[0]}"
  if [ "$extract_rc" -eq 2 ]; then
    # 退出码 2 = 载荷没匹配到 resident_dispatch 特征，脚本已拒绝写出，不会留下错的文件
    echo "  ⚠ 载荷疑似不对（没匹配到 resident_dispatch 特征），已拒绝写出，不会留下错的 $DST_SO"
  elif [ "$extract_rc" -ne 0 ]; then
    echo "  ⚠ 导出失败（仅告警，不影响 bootstrap 完成）"
  fi
else
  echo "  ⚠ 没有 python3，跳过"
fi

if [ "$fail" -ne 0 ]; then
  echo "  ✗ bootstrap 未完成，不落 .bootstrapped，下次会重试"
  exit 1
fi

say "7. 落标记"
touch "${STACK_DIR:-/opt/qqstack}/.bootstrapped"
echo "  ✓ $(date) 完成"

say "下一步"
cat <<NEXT
  1) 放好三大件：
       /opt/QQ            （QQ 3.2.32-52194 arm64）
       /opt/snowluma      （SnowLuma 2.1.1 linux-arm64）
       /opt/qqagent       （QQ Agent 2.3.0，TypeScript 版，src/index.ts 能起）
  2) cd /opt/qqagent && npm install（必须全量：tsx/typescript 是 devDependencies）
     && npm run build（可选，编出 dist/src/index.js 后启动更省内存）
  3) python3 $HERE/../patch/patch_snowluma.py ${SNOWLUMA_DIR:-/opt/snowluma}/index.mjs
       退出码：0 = 正常（方案 A 结构化补丁成功 / 已打过跳过 / 按设计不用打）
               3 = ⚠ 降级到方案 B（替身文件兜底）—— 属降级成功，
                   **不要**因此中断部署，但要人工看一眼：精度不如方案 A，
                   且替身文件有时效性（QQ 重启后 PID 会变）
               其它 = 失败，看报错
       走了哪条路也可以直接查：cat ${STACK_DIR:-/opt/qqstack}/.locks-patch-method
  4) bash $HERE/versions.sh
  5) bash $HERE/start-all.sh
NEXT
