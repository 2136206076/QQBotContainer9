#!/bin/bash
# 一键按序拉起（Termux + proot-distro Ubuntu 版）
#   虚拟屏 → 冻结热更新/建路径别名 → 协议端 → 带 hook 的 QQ → 控制台
# 首次使用先改 scripts/deploy.env
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"

export DISPLAY=${DISPLAY:-:1}
export HOME=${QQ_HOME:-/root}
RUN=${STACK_DIR:-/opt/qqstack}/run
mkdir -p "$RUN" /tmp/.X11-unix
say() { echo "[start-all] $*"; }
code() { curl -s -m 2 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

# ---------- 0) 每次开机都要做的两件事 ----------
bash "$HERE/freeze-hotupdate.sh" 2>&1 | sed 's/^/  /'
bash "$HERE/mkpath-alias.sh"     2>&1 | sed 's/^/  /'

# ---------- 1) 虚拟桌面 ----------
pgrep -x Xvfb >/dev/null 2>&1 || {
  Xvfb "$DISPLAY" -screen 0 1280x720x16 >/tmp/xvfb.log 2>&1 </dev/null &
  echo $! >"$RUN/xvfb.pid"; say "Xvfb $DISPLAY"; }
sleep 2
pgrep -x fluxbox >/dev/null 2>&1 || {
  DISPLAY="$DISPLAY" fluxbox >/tmp/fluxbox.log 2>&1 </dev/null &
  echo $! >"$RUN/fluxbox.pid"; }

if ! pgrep -x x11vnc >/dev/null 2>&1; then
  if [ -f "${STACK_DIR:-/opt/qqstack}/vncpasswd" ]; then
    x11vnc -display "$DISPLAY" -noshm -rfbauth "${STACK_DIR:-/opt/qqstack}/vncpasswd" \
      -forever -shared -rfbport "${VNC_PORT:-5900}" -localhost >/tmp/x11vnc.log 2>&1 </dev/null &
    echo $! >"$RUN/x11vnc.pid"; say "x11vnc :${VNC_PORT:-5900}"
  else
    say "缺少 ${STACK_DIR:-/opt/qqstack}/vncpasswd，先执行："
    echo "       x11vnc -storepasswd '你的密码' ${STACK_DIR:-/opt/qqstack}/vncpasswd"
  fi
fi
pgrep -f "websockif[y]" >/dev/null 2>&1 || {
  websockify --web /usr/share/novnc 127.0.0.1:${NOVNC_PORT:-6081} 127.0.0.1:${VNC_PORT:-5900} \
    >/tmp/novnc.log 2>&1 </dev/null &
  echo $! >"$RUN/websockify.pid"; say "noVNC :${NOVNC_PORT:-6081}"; }

# ---------- 2) 协议端 ----------
pgrep -f "snowluma/nod[e]" >/dev/null 2>&1 || {
  ( cd "${SNOWLUMA_DIR:-/opt/snowluma}" && ./node ./index.mjs >/tmp/snowluma.log 2>&1 </dev/null & )
  say "SnowLuma（WebUI :${SLWEBUI_PORT:-5099}）"; }
sleep 5

# ---------- 3) 导出 resident dispatch 载荷 ----------
# proot 下 memfd 版 dlopen 加载不了，slhook.c 的 dlopen 拦截器会把 /proc/self/fd/N
# 换成磁盘路径 $SNOWLUMA_RESIDENT_SO 再加载；可这个磁盘文件官方包从来不带，
# 于是拦截器 fallback 到一个不存在的文件 → hook 退回 stub → SnowLuma 一直 awaiting readiness。
# 解法：从 SnowLuma 主库内部内嵌的那份 ELF 载荷里抠出来，写到磁盘。幂等，失败也只告警。
EXTRACT_PY="$HERE/../tools/extract-resident-dispatch.py"
SRC_SO="${HOOK_SO:-${SNOWLUMA_DIR:-/opt/snowluma}/native/snowluma-linux-arm64.so}"
DST_SO="${RESIDENT_SO:-${STACK_DIR:-/opt/qqstack}/libsnowluma_linux_resident_dispatch.so}"
if [ -f "$SRC_SO" ] && [ -f "$EXTRACT_PY" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$EXTRACT_PY" --source "$SRC_SO" --target "$DST_SO" 2>&1 | sed 's/^/  /'
  extract_rc="${PIPESTATUS[0]}"
  if [ "$extract_rc" -eq 2 ]; then
    # 退出码 2 = 载荷没匹配到 resident_dispatch 特征：脚本拒绝写出，旧的 .so 保持原样
    say "⚠ 载荷疑似不对（没匹配到 resident_dispatch 特征）：已拒绝写出，$DST_SO 保持原样"
  elif [ "$extract_rc" -ne 0 ]; then
    say "⚠ 载荷导出失败：hook 会退回 stub，QQ 能起来但 SnowLuma 停在 awaiting readiness"
  fi
else
  say "跳过载荷导出（SnowLuma 主库/导出脚本/python3 缺一样，后续 hook 诊断会再试一次）"
fi

# ---------- 3.5) 回显 /proc/locks 补丁走了哪条路 ----------
# patch_snowluma.py 跑完会把实际走的路写进标记文件，以前成功/降级/跳过全都 return 0，
# 只能翻日志才分得清，容易被静默降级骗过去。这里回显出来，方案 B 要醒目提示。
METHOD_FILE="${STACK_DIR:-/opt/qqstack}/.locks-patch-method"
if [ -f "$METHOD_FILE" ]; then
  m=$(sed -n 's/^method=//p' "$METHOD_FILE" 2>/dev/null | head -1)
  n=$(sed -n 's/^method_name=//p' "$METHOD_FILE" 2>/dev/null | head -1)
  case "$m" in
    A)    say "· /proc/locks 补丁：方案 A（结构化补丁，优选）" ;;
    B)    say "⚠⚠ /proc/locks 补丁：方案 B（替身文件兜底，降级）—— 补丁上了，但精度不如方案 A，"
          say "    且替身文件有时效性（QQ 重启后 PID 会变）。建议核对 SnowLuma 版本后重打方案 A" ;;
    NONE) say "· /proc/locks 补丁：${n:-未打补丁} —— 本次没改动任何文件" ;;
    *)    say "· /proc/locks 补丁：${n:-未知状态（$m）}" ;;
  esac
  say "    ↳ 详情：cat $METHOD_FILE"
else
  say "· 还没跑过 /proc/locks 补丁（无标记文件 $METHOD_FILE）"
fi

# ---------- 4) QQ（带 hook）----------
if ! pgrep -x qq >/dev/null 2>&1; then
  rm -f "${RUNTIME_DIR:-/tmp/snowluma-${QQ_UID:-0}}/mojo."* 2>/dev/null
  ( cd "$HOME" && HOME="$HOME" DISPLAY="$DISPLAY" \
    LD_PRELOAD="${LOADER_SO:-/opt/qqstack/libslhook.so}" \
    SNOWLUMA_HOOK_SO="${HOOK_SO:-/opt/snowluma/native/snowluma-linux-arm64.so}" \
    SNOWLUMA_RESIDENT_SO="${RESIDENT_SO:-/opt/qqstack/libsnowluma_linux_resident_dispatch.so}" \
    SNOWLUMA_HOOK_RUNTIME_DIR="${RUNTIME_DIR:-/tmp/snowluma-${QQ_UID:-0}}" \
    SLHOOK_WAIT_WRAPPER="${SLHOOK_WAIT_WRAPPER:-1}" \
    SLHOOK_DELAY_MS="${SLHOOK_DELAY_MS:-5000}" \
    "${QQ_DIR:-/opt/QQ}/qq" --no-sandbox --disable-gpu --disable-software-rasterizer \
    --disable-gpu-compositing --disable-dev-shm-usage ${QQ_EXTRA_ARGS:-} \
    >/tmp/qq.log 2>&1 </dev/null & )
  say "QQ（带 hook）"
else
  say "QQ 已在运行，跳过"
fi

# ---------- 5) 控制台 ----------
if [ "$(code "http://127.0.0.1:${AGENT_PORT:-3210}/")" != "200" ]; then
  if [ -f "${AGENT_DIR:-/opt/qqagent}/src/server.js" ]; then
    ( cd "${AGENT_DIR:-/opt/qqagent}" && nohup node src/server.js >/tmp/qqagent.log 2>&1 </dev/null & )
    say "控制台（:${AGENT_PORT:-3210}）"
  else
    say "跳过控制台：${AGENT_DIR:-/opt/qqagent}/src/server.js 不存在"
  fi
fi

# ---------- 6) 等 OneBot 就绪 ----------
say "等待就绪（最多 ${BOOT_WAIT:-120}s）…"
i=0
while [ "$i" -lt "${BOOT_WAIT:-120}" ]; do
  C=$(code "http://127.0.0.1:${BOT_HTTP:-3000}/")
  [ "$C" = "401" ] || [ "$C" = "403" ] && break
  # 打过 /proc/locks 补丁的话，顺手刷新替身文件
  [ -f "${SNOWLUMA_FAKE_LOCKS:-/opt/qqstack/fake-locks}" ] && bash "$HERE/mkfake-locks.sh" >/dev/null 2>&1
  sleep 5; i=$((i+5))
done

echo
echo "  控制台   http://127.0.0.1:${AGENT_PORT:-3210}"
echo "  协议端   http://127.0.0.1:${SLWEBUI_PORT:-5099}"
echo "  扫码     noVNC: http://127.0.0.1:${NOVNC_PORT:-6081}/vnc.html"
echo "           或手机装任意 VNC 客户端连 127.0.0.1:${VNC_PORT:-5900}"
echo "  OneBot   ${BOT_HTTP:-3000}/$(code "http://127.0.0.1:${BOT_HTTP:-3000}/")  ${BOT_WS:-3001}/$(code "http://127.0.0.1:${BOT_WS:-3001}/")"
echo
curl -s -m 3 "http://127.0.0.1:${AGENT_PORT:-3210}/api/status" 2>/dev/null | head -c 300; echo
echo
echo "下一步：bash $HERE/status.sh"
