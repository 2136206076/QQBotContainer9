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
SL_RESTARTED=0     # 1 = 本节刚重启过协议端，启动分支据此无条件拉起
SL_STARTED=0       # 1 = 本节真发出了启动命令（没装好时为 0，避免谎报 ✓）
AGENT_RESTARTED=0  # 1 = 本节刚杀过控制台，第 5 步必须强制重启（旧进程可能还占着端口）
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
# 账号识别是一次性的：SnowLuma 起来那一刻 QQ 还没扫码，holders 就是空的，之后即使登录
# 成功也不会自动重扫 —— 表现就是 QQ 已登录、OneBot 却一直「未连接」。
# 所以只要 QQ 已经在跑（说明不是首次拉起，多半是用户刚扫完码），就把协议端和控制台一起
# 重启一次让它们重扫；QQ 与 Xvfb 不动，登录态不丢。
#
# 但「QQ 在跑 + 协议端在跑」不等于「没连上」：用户可能只是重开面板、或休眠后回来，
# 这时 overview 里早就 connected+accountReady 都为真了，再重启协议端纯属打断正常工作
# （OneBot 掉线、正在跑的对话全断）。所以先问一句 overview：确认已连接就跳过。
# 查询失败（控制台没起 / 非 JSON / 字段缺失）一律保守重启 —— 宁可多重启一次，
# 也别让「扫完码却一直未连接」这个原始 bug 复发。
SL_DIR="${SNOWLUMA_DIR:-/opt/snowluma}"
SL_PIDFILE="$RUN/snowluma.pid"

# pidfile 只当线索：/proc/<pid>/cmdline 里必须真有 index.mjs 才认，防 PID 复用（与 stop-all.sh 同口径）
sl_is_snowluma() {
  local pid="${1:-}" line="" hit=""
  [ -n "$pid" ] || return 1
  [ "$pid" = "$$" ] && return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' line || [ -n "$line" ]; do
    case "$line" in *index.mjs*) hit=1; break ;; esac
  done < "/proc/$pid/cmdline" 2>/dev/null
  [ -n "$hit" ]
}

# 判据双路：pgrep 优先（绝对路径启动后 argv 里必然带 snowluma/node）；
# pidfile 兜底（老版本/手动用相对路径起的 ./node ./index.mjs，cmdline 里没有 snowluma/node，
# pgrep 抓不到 —— 只看 pgrep 的话重启分支永不触发，下次启动还会起第二个实例撞端口）
sl_pids() {
  local out="" fpid=""
  out="$(pgrep -f 'snowluma/nod[e]' 2>/dev/null | tr '\n' ' ' || true)"
  if [ -f "$SL_PIDFILE" ]; then
    fpid="$(tr -dc '0-9' < "$SL_PIDFILE" 2>/dev/null || true)"
    if [ -n "$fpid" ] && sl_is_snowluma "$fpid"; then
      case " $out " in *" $fpid "*) ;; *) out="$out$fpid " ;; esac
    fi
  fi
  printf '%s' "$out"
}

# overview 已连上（connected 且 accountReady 都为真）→ 别打断
# python 只留单行 -c：多行 -c 在 sh/bash 里转义太容易踩坑，出错就 return 1（= 保守重启）
sl_already_connected() {
  local ov="" st=""
  ov="$(curl -s -m 3 "http://127.0.0.1:${AGENT_PORT:-3081}/api/overview" 2>/dev/null || true)"
  [ -n "$ov" ] || return 1
  st="$(printf '%s' "$ov" | python3 -c "import sys,json;d=json.load(sys.stdin);rt=d.get('runtime') or {};ob=rt.get('onebot') or {};c=rt.get('napcatConnected');c=ob.get('connected') if c is None else c;print('ready' if (c is True and ob.get('accountReady') is True) else 'notready')" 2>/dev/null || true)"
  [ "$st" = "ready" ]
}

need_restart=0
if pgrep -x qq >/dev/null 2>&1 && [ -n "$(sl_pids)" ]; then
  need_restart=1
  if sl_already_connected; then
    need_restart=0
    say "QQ 与协议端都在跑，overview 显示已连接（accountReady=true）→ 跳过重启，不打断"
  fi
fi

if [ "$need_restart" = "1" ]; then
  say "QQ 已在运行 → 重启协议端以重新识别账号（QQ 登录态保留）"
  for x in $(sl_pids); do kill "$x" 2>/dev/null || true; done
  # 控制台是 OneBot 客户端，一起重启可立刻重连，不用等 1s→30s 退避。
  # pidfile 只当线索：/proc/<pid>/cmdline 里含 index.js / index.ts 才杀，防 PID 复用误杀无辜进程
  AG_KILL_PID=""
  if [ -f "$RUN/qqagent.pid" ]; then
    ap="$(tr -dc '0-9' < "$RUN/qqagent.pid" 2>/dev/null || true)"
    if [ -n "$ap" ] && grep -qa -e 'index\.js' -e 'index\.ts' "/proc/$ap/cmdline" 2>/dev/null; then
      kill "$ap" 2>/dev/null || true
      AG_KILL_PID="$ap"
    elif [ -n "$ap" ]; then
      say "· 控制台 pidfile 已失效（pid $ap 早已不是控制台进程），跳过 kill"
    fi
  fi
  # 有界等待：最多 10s。以前只 sleep 2，而 SnowLuma 收到 SIGTERM 后可能 3s 才退，
  # 2s 后 pgrep 仍命中 → 以为「还在跑」就跳过重启 → 旧进程随后真死，协议端与控制台双停
  i=0
  while [ "$i" -lt 10 ] && [ -n "$(sl_pids)" ]; do sleep 1; i=$((i+1)); done
  if [ -n "$(sl_pids)" ]; then
    say "⚠ 协议端 ${i}s 内没退干净，kill -9 兜底"
    for x in $(sl_pids); do kill -9 "$x" 2>/dev/null || true; done
    sleep 1
  fi
  # 被杀的旧控制台也要等它让出 3081，否则新实例绑不上端口（5s 后仍赖着就 -9）
  if [ -n "$AG_KILL_PID" ]; then
    i=0
    while [ "$i" -lt 5 ] && [ -d "/proc/$AG_KILL_PID" ]; do sleep 1; i=$((i+1)); done
    if [ -d "/proc/$AG_KILL_PID" ]; then
      kill -9 "$AG_KILL_PID" 2>/dev/null || true
      sleep 1
    fi
  fi
  rm -f "$SL_PIDFILE" "$RUN/qqagent.pid"
  SL_RESTARTED=1
  # 第 5 步靠它强制重启控制台：旧进程就算还占着 3081，也必须重新拉起，
  # 否则「端口被占 → 判为不用启动」会让控制台永久停着
  AGENT_RESTARTED=1
fi

# 启动分支不看 pgrep：刚杀过就无条件拉起。否则「检查通过 → 进程正好死掉」这个时间窗
# 会让协议端彻底没人管（pgrep 那一瞬间仍命中，于是整段被跳过）
if [ "$SL_RESTARTED" = "1" ] || [ -z "$(sl_pids)" ]; then
  if [ -x "$SL_DIR/node" ] && [ -f "$SL_DIR/index.mjs" ]; then
    # 绝对路径启动：cmdline 里才会出现 .../snowluma/node，pgrep 判据才作数。
    # 仍然 cd 到该目录、./index.mjs 不改 —— 它内部按相对路径找 native/、config/ 之类。
    # exec 不能省：`cd && cmd &` 这种 and-list 后台化时 bash 可能再 fork 一层，
    # 那样 $! 记的是个马甲 shell 的 pid、瞬间就退，pidfile 就废了（pidfile 兜底靠它）。
    ( cd "$SL_DIR" && exec "$SL_DIR/node" ./index.mjs >/tmp/snowluma.log 2>&1 </dev/null &
      echo $! >"$SL_PIDFILE" )
    SL_STARTED=1
  else
    say "✗ 协议端没装好：$SL_DIR/node 或 $SL_DIR/index.mjs 不存在（先跑部署第 2 步）"
  fi
fi
# 起没起来要验过再报，不许无条件 ✓：目录不存在 / 端口起不来都得如实说。
# sleep 5 只在真发出启动命令时才等 —— 已连接跳过的快路径不该白等 5 秒。
if [ "$SL_STARTED" = "1" ]; then
  sleep 5
  SL_OK=0
  [ -n "$(sl_pids)" ] && SL_OK=1
  if [ "$SL_OK" = "0" ]; then
    case "$(code "http://127.0.0.1:${SLWEBUI_PORT:-5099}/")" in
      000|"") : ;;
      *)      SL_OK=1 ;;
    esac
  fi
  if [ "$SL_OK" = "1" ]; then
    say "SnowLuma（WebUI :${SLWEBUI_PORT:-5099}）"
  else
    say "✗ 协议端没起来，看 /tmp/snowluma.log"
  fi
fi

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

# ---------- 5) 控制台（QQ Agent，TypeScript 项目）----------
# 启动方式二选一，优先编译产物：
#   node dist/src/index.js   —— 部署时 npm run build（tsc）编出来的，纯 node 跑，省内存、启动快
#   tsx src/index.ts         —— 官方 npm start 的用法，现编现跑；dist 没编出来时兜底
# 不强制依赖 dist：tsconfig 开了 noUnusedLocals，scripts/ 下测试脚本一有未用变量 tsc 就编不过，
# 把"控制台能不能起来"押在编译上不划算，所以两条路都留着。
# 顺序说明：Agent 是 OneBot 客户端，主动连 SnowLuma 的正向 WS（默认 ws://127.0.0.1:3001，
# 即 deploy.env 的 BOT_WS）。它在第 5 步先起、第 6 步才等 OneBot 就绪，中间连不上只会在
# 日志里打 "等待重连 OneBot" 并按 1s→30s 退避重试（config/app.yaml 的 napcat.reconnect），
# SnowLuma 起来后自动连上 —— 所以不需要把它挪到第 6 步之后（挪过去反而要多等一轮就绪）。
# 第 2 步刚杀过控制台（AGENT_RESTARTED=1）时不再看端口：旧进程可能还没退干净、3081 仍是
# 200，按端口判就会跳过启动 → 控制台永久停。杀过就无条件重启。
if [ "${AGENT_RESTARTED:-0}" = "1" ] || [ "$(code "http://127.0.0.1:${AGENT_PORT:-3081}/")" != "200" ]; then
  AGENT_HOME="${AGENT_DIR:-/opt/qqagent}"
  if [ -f "$AGENT_HOME/dist/src/index.js" ]; then
    # 顺手写 pidfile（run/ 下，和 Xvfb/x11vnc 一个惯例）：stop-all.sh 靠它精确点名，
    # 比按命令行匹配可靠。exec 不能省 —— `cd && nohup node &` 这种 and-list 后台化时
    # bash 可能再 fork 一层，$! 就成了马甲 shell 的 pid，第 2 步重启时按 cmdline 校验会被
    # 判成「pidfile 已失效」而跳过 kill，旧控制台就留着占 3081 了。
    ( cd "$AGENT_HOME" && exec nohup node dist/src/index.js >/tmp/qqagent.log 2>&1 </dev/null &
      echo $! >"$RUN/qqagent.pid" )
    say "控制台（node dist/src/index.js，:${AGENT_PORT:-3081}）"
  elif [ -f "$AGENT_HOME/src/index.ts" ] && [ -x "$AGENT_HOME/node_modules/.bin/tsx" ]; then
    ( cd "$AGENT_HOME" && exec nohup ./node_modules/.bin/tsx src/index.ts >/tmp/qqagent.log 2>&1 </dev/null &
      echo $! >"$RUN/qqagent.pid" )
    say "控制台（tsx src/index.ts，:${AGENT_PORT:-3081}）"
  else
    say "跳过控制台：$AGENT_HOME 里既没有 dist/src/index.js 也没有可执行的 tsx（Agent 没装好？看部署第 5 步日志）"
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
echo "  控制台   http://127.0.0.1:${AGENT_PORT:-3081}（QQ Agent，要自备 LLM API Key，在面板「模型接入」里填）"
echo "  协议端   http://127.0.0.1:${SLWEBUI_PORT:-5099}"
echo "  扫码     noVNC: http://127.0.0.1:${NOVNC_PORT:-6081}/vnc.html"
echo "           或手机装任意 VNC 客户端连 127.0.0.1:${VNC_PORT:-5900}"
echo "  OneBot   ${BOT_HTTP:-3000}/$(code "http://127.0.0.1:${BOT_HTTP:-3000}/")  ${BOT_WS:-3001}/$(code "http://127.0.0.1:${BOT_WS:-3001}/")"
echo
# 新版 Agent 没有 /api/status；/api/overview 才是既有模型又有 OneBot 连接状态的那一个
curl -s -m 3 "http://127.0.0.1:${AGENT_PORT:-3081}/api/overview" 2>/dev/null | head -c 300; echo
echo
echo "下一步：bash $HERE/status.sh"
