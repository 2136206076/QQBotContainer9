#!/bin/bash
# 运行态体检（Termux + proot-distro 版）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
say() { printf '%-14s %s\n' "$1" "$2"; }
p() { pgrep -x "$1" >/dev/null 2>&1 && echo 运行中 || echo 未运行; }
code() { curl -s -m 2 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

say "环境" "$(grep -q 'installed-rootfs' /proc/self/mounts 2>/dev/null && echo 'proot 容器内' || echo '（不在 proot 里？）')"
say "Xvfb"     "$(p Xvfb)"
say "x11vnc"   "$(p x11vnc)"
say "QQ"       "$(p qq)"
say "hook 已加载" "$(for q in $(pgrep -x qq 2>/dev/null); do grep -qa snowluma-linux-arm64.so /proc/$q/maps 2>/dev/null && { echo 是; break; }; done)"
say "SnowLuma" "$(pgrep -f 'snowluma/nod[e]' >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
say "OneBot ${BOT_HTTP:-3000}" "$(code http://127.0.0.1:${BOT_HTTP:-3000}/)  (401/403=正常)"
say "OneBot ${BOT_WS:-3001}" "$(code http://127.0.0.1:${BOT_WS:-3001}/)  (426=正常)"
say "控制台 ${AGENT_PORT:-3210}" "$(code http://127.0.0.1:${AGENT_PORT:-3210}/)"
say "虚拟屏 ${NOVNC_PORT:-6081}" "$(code http://127.0.0.1:${NOVNC_PORT:-6081}/)"
echo
curl -s -m 4 "http://127.0.0.1:${AGENT_PORT:-3210}/api/status" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('OneBot :', '已连接' if d['onebot']['connected'] else '未连接', d['onebot'].get('self') or '')
    print('模型   :', d['orchestrator'].get('model') or '(未配置)')
except Exception:
    print('控制台未启动或状态读取失败')"
echo
echo "QQ 最近 hook 日志："
grep -a "slhook" /tmp/qq.log 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  （无）"
