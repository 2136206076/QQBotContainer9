#!/bin/bash
# 全停（保留登录态）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
STACK_DIR=${STACK_DIR:-/opt/qqstack}
AGENT_DIR=${AGENT_DIR:-/opt/qqagent}

# 先杀 QQ（用 pidfile 兜底，避免误杀宿主同名进程）
pkill -x qq 2>/dev/null
for x in $(pgrep -f 'snowluma/nod[e]' 2>/dev/null); do kill "$x" 2>/dev/null; done
# ---- QQ Agent（原版 JS：入口 src/server.js；老容器里可能是旧版 dist/src/index.js 或 src/index.ts）----
# 控制台进程怎么认：先走 pidfile，pidfile 没有或失效时再扫 /proc 兜底。
# 以前是 pkill -f "dist/src/inde[x].js"：pkill -f 匹配的是完整命令行，没锚点的话
# 命令行里出现过这个字符串的通杀 —— 别的目录下的同名文件
# （/tmp/otherproject/dist/src/index.js）、包装用的 bash -c、以及命令行里恰好带了这个
# 字符串的测试 shell 全会被连坐。
# 关于 [x]：那是"用字符类包住字面字符"的写法，只能让 pkill 不匹配到 pkill 自己的命令行，
# 挡不住"命令行里恰好带了这个字符串"的其它进程 —— 所以光靠它不够，真锚点在下面这两条路：
#   路线 1  pidfile：$STACK_DIR/run/qqagent.pid（沿用项目里 run/*.pid 的惯例）
#   路线 2  /proc：先一次 grep 捞出"命令行里出现过入口文件名"的候选，
#           再逐个校验：cwd 必须解析到 $AGENT_DIR（相对路径启动的场景，命令行里没有
#           绝对路径，只能看 cwd），或 argv 里带着 $AGENT_DIR 前缀的绝对路径
#           （cwd 不在 Agent 目录时用这个）。
# 三个入口都要认：src/server.js（现在的内置版）、dist/src/index.js / src/index.ts（旧版残留）。
# 三道额外保险（都为了不误杀）：进程必须是 node/tsx 这类 JS 运行时（否则在 Agent 目录里
# tail -f src/server.js 也会被杀）；不能是 shell（bash -c '... server.js ...' 只是路过，
# 它里面那个 node 才是目标）；pidfile 里的号码只当线索（进程早退、pid 被复用都要防）。
AGENT_PID_FILE="$STACK_DIR/run/qqagent.pid"
AGENT_PIDS=""
# 路径按真实路径比：cwd 是 readlink -f 出来的，两边都归一，软链接才不会误判
AGENT_DIR_REAL="$(readlink -f "$AGENT_DIR" 2>/dev/null || printf '%s' "$AGENT_DIR")"

# 读一次 /proc/<pid>/cmdline（read 是内建，不 fork 外部命令）：
# A0 = argv[0]，HIT_* = 是否有参数以对应入口名结尾（要求是整个参数，不是半截字符串）
# SRV = 现在的内置版入口 src/server.js；JS/TS = 旧版残留的 dist/src/index.js / src/index.ts
A0=""; HIT_SRV=""; HIT_JS=""; HIT_TS=""; HIT_ABS_SRV=""; HIT_ABS_JS=""; HIT_ABS_TS=""
scan_cmdline() {
  local line first=1
  A0=""; HIT_SRV=""; HIT_JS=""; HIT_TS=""; HIT_ABS_SRV=""; HIT_ABS_JS=""; HIT_ABS_TS=""
  while IFS= read -r -d '' line || [ -n "$line" ]; do
    [ "$first" = "1" ] && { A0="$line"; first=0; }
    [ -z "$HIT_SRV" ]     && case "$line" in *"src/server.js") HIT_SRV=1 ;; esac
    [ -z "$HIT_JS" ]     && case "$line" in *"dist/src/index.js") HIT_JS=1 ;; esac
    [ -z "$HIT_TS" ]     && case "$line" in *"src/index.ts") HIT_TS=1 ;; esac
    [ -z "$HIT_ABS_SRV" ] && case "$line" in *"$AGENT_DIR/src/server.js") HIT_ABS_SRV=1 ;; esac
    [ -z "$HIT_ABS_JS" ] && case "$line" in *"$AGENT_DIR/dist/src/index.js") HIT_ABS_JS=1 ;; esac
    [ -z "$HIT_ABS_TS" ] && case "$line" in *"$AGENT_DIR/src/index.ts") HIT_ABS_TS=1 ;; esac
  done < "/proc/$1/cmdline" 2>/dev/null
  return 0
}

# 是不是"本项目 Agent 目录下的那个控制台进程"
is_agent_proc() {
  local pid="$1" comm="" cwd=""
  [ "$pid" = "$$" ] && return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  read -r comm < "/proc/$pid/comm" 2>/dev/null || comm=""
  case "$comm" in bash|sh|dash|zsh|ksh|fish|ash|busybox) return 1 ;; esac
  scan_cmdline "$pid"
  case "${A0##*/}" in node|nodejs|tsx|npx|bun|deno) ;; *) return 1 ;; esac
  cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
  if [ "$cwd" = "$AGENT_DIR_REAL" ]; then
    [ -n "$HIT_SRV" ] && return 0
    [ -n "$HIT_JS" ] && return 0
    [ -n "$HIT_TS" ] && return 0
  fi
  [ -n "$HIT_ABS_SRV" ] && return 0
  [ -n "$HIT_ABS_JS" ] && return 0
  [ -n "$HIT_ABS_TS" ] && return 0
  return 1
}

L="$AGENT_DIR/data/qq-agent.lock"
# 老版本残留的 lock：同样只当线索，cmdline 校验通过才杀 —— lock 文件在 rootfs 里跨重启保留，
# PID 被复用时裸 kill 会误伤无辜进程（三个入口都认：server.js / index.js / index.ts）
if [ -f "$L" ]; then
  lp=$(tr -dc '0-9' < "$L" 2>/dev/null || true)
  [ -n "$lp" ] && grep -qa -e 'server\.js' -e 'index\.js' -e 'index\.ts' "/proc/$lp/cmdline" 2>/dev/null && kill "$lp" 2>/dev/null
fi

# 路线 1：pidfile（start-all.sh 写的）。先校验再杀，pid 被复用时不会杀错人
if [ -f "$AGENT_PID_FILE" ]; then
  p=$(tr -dc '0-9' < "$AGENT_PID_FILE" 2>/dev/null || true)
  if [ -n "$p" ] && is_agent_proc "$p"; then AGENT_PIDS="$AGENT_PIDS $p"; fi
  rm -f "$AGENT_PID_FILE"    # 顺手清掉，下次 stop 不会再拿旧号码找人
fi
# 路线 2：扫 /proc（覆盖手动 cd 进目录用相对路径启动、没有 pidfile 的情况）
# 一次 grep 扫完所有 /proc/<pid>/cmdline，比逐个 pid 起进程快一个数量级
CAND=$(grep -l -s -a -F -e 'src/server.js' -e 'dist/src/index.js' -e 'src/index.ts' /proc/[0-9]*/cmdline 2>/dev/null || true)
for d in $CAND; do
  p=${d#/proc/}; p=${p%/cmdline}
  case " $AGENT_PIDS " in *" $p "*) continue ;; esac
  is_agent_proc "$p" && AGENT_PIDS="$AGENT_PIDS $p"
done
for p in $AGENT_PIDS; do kill -TERM "$p" 2>/dev/null || true; done

# 给 3s 优雅退出（自己先走的就不等），还赖着的再上 -9
i=0
while [ "$i" -lt 3 ]; do
  left=0
  for p in $AGENT_PIDS; do [ -d "/proc/$p" ] && left=$((left + 1)); done
  [ "$left" -eq 0 ] && break
  sleep 1; i=$((i + 1))
done
for p in $AGENT_PIDS; do
  [ -d "/proc/$p" ] && { kill -KILL "$p" 2>/dev/null || true; }
done

# ---- run/*.pid 收尾 ----
# 这里的 pidfile 只当"线索"，不能当"事实"。run/ 在 rootfs 里跨重启保留，而 PID 会被系统
# 复用：老号码被别的无关进程接手时，裸 kill "$(cat "$f")" 就会把无辜进程杀掉 —— 和文件
# 开头那段注释讲的是同一件事（那里已经用 scan_cmdline 校验控制台进程，这里一并收口）。
# 做法：按 pidfile 文件名推断该进程"命令行里必须出现的特征"，/proc/<pid>/cmdline 里真匹配
# 上了才 kill。认不出来的 pidfile 一律不杀 —— 宁可漏杀（残留的 Xvfb/协议端下次 start 会
# 收拾），也不要误杀。所有失败路径都 return 0：stop-all 必须能一路跑完把状态打出来。
pidfile_cmdline_key() {
  case "${1##*/}" in
    snowluma.pid)   printf '%s' 'index\.mjs' ;;        # 协议端：node <...>/index.mjs
    xvfb.pid)       printf '%s' 'Xvfb' ;;
    fluxbox.pid)    printf '%s' 'fluxbox' ;;
    x11vnc.pid)     printf '%s' 'x11vnc' ;;
    websockify.pid) printf '%s' 'websockify' ;;
    # qqagent.pid 不在表里（有意为之）：控制台进程走上面的 is_agent_proc()，
    # 那里有 comm 白名单（必须是 node/tsx 之类）＋ cwd/绝对路径双重校验。
    # 只 grep cmdline 里的 server.js 是不够的 —— `tail -f .../server.js`、
    # `vim src/server.js`、恰恰带着这串路径的 shell 全都会被连坐误杀。
    *)              return 1 ;;
  esac
  return 0
}

kill_from_pidfile() {
  local f="${1:-}" pid="" key="" name=""
  [ -n "$f" ] && [ -f "$f" ] || return 0
  name="${f##*/}"
  # 号码可能带换行/空格，只留数字
  pid="$(tr -dc '0-9' < "$f" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  [ "$pid" = "$$" ] && return 0
  # /proc 项没了说明进程早退，没什么可杀的
  [ -r "/proc/$pid/cmdline" ] || return 0
  # 控制台单独走 is_agent_proc()：它是「node/tsx 在 Agent 目录里跑 server.js」，
  # 不是「命令行里出现过 server.js」—— 后者会把 tail -f / less / 编辑器的进程一起干掉。
  if [ "$name" = "qqagent.pid" ]; then
    if is_agent_proc "$pid"; then
      kill "$pid" 2>/dev/null || true
    else
      echo "· 跳过 run/$name：pid $pid 已不是控制台进程"
    fi
    return 0
  fi
  key="$(pidfile_cmdline_key "$f" 2>/dev/null || true)"
  if [ -z "$key" ]; then
    echo "· 跳过 run/$name：未知 pidfile，无法校验身份，不杀"
    return 0
  fi
  # cmdline 是 NUL 分隔的，grep 单行匹配照样命中；-a 防被当二进制跳过
  if grep -qa "$key" "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  else
    echo "· 跳过 run/$name：pid $pid 已不是该进程"
  fi
  return 0
}

sleep 2
pkill -9 -x qq 2>/dev/null
for f in "$STACK_DIR"/run/*.pid; do kill_from_pidfile "$f"; done

sleep 2
echo "已停止：qq=$(pgrep -c -x qq 2>/dev/null || true) \
snowluma=$(pgrep -f 'snowluma/nod[e]' 2>/dev/null | wc -l) \
控制台=$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:${AGENT_PORT:-3081}/ 2>/dev/null)"
echo "（虚拟屏 Xvfb/x11vnc 保留，想一起停：pkill -x Xvfb; pkill -x x11vnc; pkill -f websockify）"
