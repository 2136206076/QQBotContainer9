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

PKG_DIR="${STACK_DIR:-/opt/qqstack}/pkgs"
OFFLINE_DEBS=$(ls "$PKG_DIR"/*.deb 2>/dev/null | wc -l)

# ---- 桌面数据库工具桩：必须放在 dpkg 装包**之前** ----
# hicolor-icon-theme / shared-mime-info / linuxqq 的 postinst 都会调
# update-desktop-database、update-mime-database、gtk-update-icon-cache。
# 容器里没有桌面环境，这几条命令做出的事（写 mimeinfo.cache / icon-theme.cache）
# 毫无意义，但**命令不存在**会让 postinst 以非 0 退出 → dpkg 把包装成
# 「half-configured」，之后每次 dpkg/apt 都重复报同一个错，重装 QQ 也会被卡住
# （v1.2 的日志里 linuxqq.postinst: line 10: update-desktop-database: command not found
#   就是这个原因）。
# 放 /usr/bin 而不是 /usr/local/bin：dpkg 调 postinst 时的 PATH 里一定有 /usr/bin。
# shared-mime-info 自带真正的 update-mime-database，装的时候会把桩覆盖掉，不影响。
for b in update-desktop-database update-mime-database gtk-update-icon-cache xdg-desktop-menu; do
  if ! command -v "$b" >/dev/null 2>&1; then
    printf '#!/bin/sh\n# proot 容器桩：无桌面环境，这类数据库更新是装饰性的\nexit 0\n' >"/usr/bin/$b" 2>/dev/null \
      && chmod +x "/usr/bin/$b" 2>/dev/null && echo "  + /usr/bin/$b（桩）"
  fi
done

if [ "$OFFLINE_DEBS" -ge 200 ]; then
  # ===== 离线路径 =====
  # APK 已经把 290 个 arm64 包打进 assets，部署时解压到 $PKG_DIR。
  # 一次 dpkg -i 给全部包：dpkg 内部会按 Pre-Depends/Depends 做拓扑排序，
  # 比 apt 从网络解析快得多，而且完全不依赖网络。
  #
  # --force-confnew：包里有少量 /etc 配置文件是新版格式（fonts.conf、gai.conf），
  #   不问就覆盖，避免 proot 里没有 tty 时 dpkg 卡在交互提问上。
  # --force-depends：base rootfs 里的 libc6 等版本比索引略旧，dpkg 会保守地拒绝，
  #   但实际 ABI 兼容，强行装上再由后面的 configure 修。
  echo "  · 离线模式：本地 $OFFLINE_DEBS 个 arm64 包，dpkg 本地安装（不联网）"
  echo "  · 这一步要解 300MB 左右，proot 下大约 5~12 分钟，请别退出"
  dpkg -i --force-confnew --force-depends "$PKG_DIR"/*.deb >/tmp/dpkg-unpack.log 2>&1
  dpkg_rc=$?
  # configure 分两遍：第一遍处理正常顺序，第二遍捡前面因为依赖还没配好而跳过的包
  dpkg --configure -a >/tmp/dpkg-cfg1.log 2>&1
  dpkg --configure -a >/tmp/dpkg-cfg2.log 2>&1
  if [ "$dpkg_rc" -ne 0 ]; then
    echo "  ⚠ dpkg -i 退出码 $dpkg_rc（部分包可能没配上），最后 8 行："
    tail -8 /tmp/dpkg-unpack.log | sed 's/^/    /'
  fi
  # 有些包的 postinst 会调 fc-cache / update-desktop-database，在 proot 里可能报错，
  # 那些都是装饰性的，不影响运行 —— 真正要看的是下面这些可执行文件在不在。
  # 字体缓存交给 fonts-noto-cjk 的 postinst 去做（它内部就会调 fc-cache）；
  # 这里再跑一遍 -f 等于把 93MB 的 TTC 重新哈希一次（proot 下要好几分钟），纯浪费。
else
  # ===== 联网路径（内置包缺失时的兜底，保持原行为）=====
  echo "  · 没找到本地包（$PKG_DIR），改为联网 apt 安装"
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
    ca-certificates curl wget xz-utils unzip \
    procps psmisc \
    xvfb openbox x11vnc websockify python3-websockify \
    libgbm1 libnss3 libasound2t64 libgtk-3-0t64 libxshmfence1 libxdamage1 \
    libdrm2 libxkbcommon0 libxkbcommon-x11-0 fontconfig fonts-noto-cjk python3 \
    || fail=1
fi

command -v curl >/dev/null && command -v python3 >/dev/null \
  && command -v Xvfb >/dev/null && command -v x11vnc >/dev/null \
  && echo "  ✓ 系统包完成" \
  || { echo "  ✗ 关键包缺失（curl/python3/Xvfb/x11vnc）"; fail=1; }

say "2. Node 运行时（QQ Agent 要 ≥${NODE_MIN:-22.16.0}）"
# QQ Agent 的硬门槛是 22.16.0，不是 22：它用 Node 内置 SQLite，而 FTS5 与
# DatabaseSync.isTransaction 这两个能力都是 22.16.0 才编进 Node 的
# （22.13~22.15 会得到 "no such module: fts5"，数据库建不起来）。
# 用 sort -V 做真正的版本比较：cur >= min 时排序后第一行是 min。
node_min_ok() {
  local bin="${1:-node}" cur
  cur=$("$bin" -v 2>/dev/null | sed -n 's/^v\([0-9][0-9.]*\).*/\1/p')
  [ -n "$cur" ] || return 1
  [ "$(printf '%s\n%s\n' "${NODE_MIN:-22.16.0}" "$cur" | sort -V | head -n1)" = "${NODE_MIN:-22.16.0}" ]
}

install_node() {
  # $1 = NodeSource 通道（22.x / 24.x）—— 只有离线资源全缺时才会走到这里
  mkdir -p /etc/apt/keyrings
  if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; then
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$1 nodistro main" \
      >/etc/apt/sources.list.d/nodesource.list
    apt-get update -qq && apt-get install -y nodejs
  fi
}

# 首选：SnowLuma 自带的那份 node（v24.x，随协议端一起解压，不占额外下载）。
# 已核对它带 fts5 与 isTransaction —— 正是 QQ Agent 要的两个能力。
# 用它还有个额外好处：整个容器只有一套 node，不会出现 /usr/bin/node 与
# SnowLuma 内部 node 版本不一致导致的诡异行为。
SL_NODE="${SNOWLUMA_DIR:-/opt/snowluma}/node"
if [ -x "$SL_NODE" ] && node_min_ok "$SL_NODE"; then
  "$SL_NODE" -v 2>/dev/null | sed 's/^/  ✓ 复用 SnowLuma 自带 node /'
  mkdir -p /usr/local/bin
  ln -sf "$SL_NODE" /usr/local/bin/node
  # /usr/bin 一定在 PATH 里，/usr/local/bin 不一定（proot 启动时的环境变量由 App 决定）
  [ -e /usr/bin/node ] || ln -sf "$SL_NODE" /usr/bin/node
  echo "  ✓ node → $(command -v node)（$(node -v 2>/dev/null)）"
elif node_min_ok node; then
  echo "  ✓ 已有 $(node -v)（≥${NODE_MIN:-22.16.0}）"
else
  echo "  · 没有可用的 SnowLuma node，改为联网装 NodeSource node_22.x"
  install_node 22.x
  if ! node_min_ok node; then
    echo "  · 22.x 通道不给力，改试 node_24.x（LTS）"
    install_node 24.x
  fi
  if node_min_ok node; then
    echo "  ✓ $(node -v)"
  else
    echo "  ✗ Node ≥${NODE_MIN:-22.16.0} 不可用（QQ Agent 会起不来：no such module: fts5）"
    fail=1
  fi
fi

say "3. 目录"
mkdir -p "${STACK_DIR:-/opt/qqstack}/run" /tmp/.X11-unix
if [ -d "$HERE/../bin" ]; then cp -f "$HERE"/../bin/* "${STACK_DIR:-/opt/qqstack}/" 2>/dev/null; fi
ls -l "${STACK_DIR:-/opt/qqstack}/"

say "4. hook 载入器 libslhook.so"
HOOK_DST="${STACK_DIR:-/opt/qqstack}/libslhook.so"
# 首选内置的预编译版（构建 APK 时用 aarch64-linux-gnu-gcc 编好，70KB）。
# 这样容器里不需要 gcc/build-essential —— 那一套要 200MB 以上，纯为编这一个
# 70KB 的 .so，不值得打进 APK，也没必要在手机上花两分钟编译。
# 校验两点：ELF magic（7f454c46）和 e_machine=0xB7（AArch64 小端），防止
# 误把宿主架构的 .so 塞进来 —— 那种错误在真机上表现为 QQ 直接闪退，很难查。
hook_ok() {
  [ -f "$1" ] || return 1
  [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || return 1
  [ "$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')" = "b700" ] || return 1
}
if hook_ok "$HOOK_DST"; then
  echo "  ✓ 使用内置预编译版（$(wc -c <"$HOOK_DST") 字节，aarch64 ELF）"
elif command -v gcc >/dev/null 2>&1; then
  echo "  · 内置 .so 不可用，用容器内 gcc 编译"
  SRC="$HERE/../bin/slhook.c"
  [ -f "$SRC" ] || SRC="${STACK_DIR:-/opt/qqstack}/slhook.c"
  if [ -f "$SRC" ]; then
    gcc -shared -fPIC -O2 -o "$HOOK_DST" "$SRC" -ldl -lpthread \
      && echo "  ✓ 已生成 $HOOK_DST" \
      || { echo "  ✗ 编译失败，看上面的报错"; fail=1; }
  else
    echo "  ⚠ 没找到 slhook.c（应放在 bin/ 目录）"
    fail=1
  fi
else
  echo "  ✗ 内置 .so 缺失且没有 gcc —— hook 起不来，QQ 会连不上协议端"
  echo "    → 重装 APK（内置包里有 libslhook.so），或联网 apt install build-essential 后重跑"
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
# 包已经解进系统了，$PKG_DIR 里那 195MB 的 .deb 留着只占地方。
# 万一以后要重装，重跑部署第 4 步会从 APK 里重新解出来（约 20 秒）。
if [ -d "$PKG_DIR" ]; then
  rm -rf "$PKG_DIR" 2>/dev/null && echo "  · 已清理依赖包缓存（约 195MB）"
fi
echo "  ✓ $(date) 完成"

say "下一步"
cat <<NEXT
  1) 放好三大件：
       /opt/QQ            （QQ 3.2.32-52194 arm64）
       /opt/snowluma      （SnowLuma 2.1.1 linux-arm64）
       /opt/qqagent       （QQ Agent 0.4.0，原版 JS，入口 src/server.js）
  2) /opt/qqagent 由部署第 5 步用内置包解压得到（离线，不需要 npm install，也不需要编译）
     手动重装：tar xzf ${STACK_DIR:-/opt/qqstack}/agent/qqagent.tar.gz -C /opt/qqagent
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
