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

say "2. Node（Ubuntu 24.04 的 apt 源是 18.x，Agent 要 ≥20）"
if node -v 2>/dev/null | grep -qE '^v(2[0-9]|3[0-9])'; then
  echo "  ✓ 已装 $(node -v)"
else
  mkdir -p /etc/apt/keyrings
  if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; then
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
      >/etc/apt/sources.list.d/nodesource.list
    apt-get update -qq && apt-get install -y nodejs
  fi
  if node -v 2>/dev/null | grep -qE '^v(2[0-9]|3[0-9])'; then
    echo "  ✓ $(node -v)"
  else
    echo "  ✗ Node 22 安装失败"
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
       /opt/qqagent       （QQ Agent，node src/server.js 能起）
  2) cd /opt/qqagent && npm install --omit=dev
  3) python3 $HERE/../patch/patch_snowluma.py ${SNOWLUMA_DIR:-/opt/snowluma}/index.mjs
  4) bash $HERE/versions.sh
  5) bash $HERE/start-all.sh
NEXT
