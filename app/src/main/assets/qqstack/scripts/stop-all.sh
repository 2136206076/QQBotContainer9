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
L="$AGENT_DIR/data/qq-agent.lock"
[ -f "$L" ] && kill "$(tr -dc '0-9' < "$L")" 2>/dev/null
pkill -f "QQagent/src/server[.]js" 2>/dev/null
pkill -f "qqagent/src/server[.]js" 2>/dev/null
sleep 2
pkill -9 -x qq 2>/dev/null
for f in "$STACK_DIR"/run/*.pid; do [ -f "$f" ] || continue; kill "$(cat "$f")" 2>/dev/null; done

sleep 2
echo "已停止：qq=$(pgrep -c -x qq 2>/dev/null || echo 0) \
snowluma=$(pgrep -f 'snowluma/nod[e]' 2>/dev/null | wc -l) \
控制台=$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:${AGENT_PORT:-3210}/ 2>/dev/null)"
echo "（虚拟屏 Xvfb/x11vnc 保留，想一起停：pkill -x Xvfb; pkill -x x11vnc; pkill -f websockify）"
