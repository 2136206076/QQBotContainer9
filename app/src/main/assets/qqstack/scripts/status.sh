#!/bin/bash
# 运行态体检（Termux + proot-distro 版）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
say() { printf '%-14s %s\n' "$1" "$2"; }
p() { pgrep -x "$1" >/dev/null 2>&1 && echo 运行中 || echo 未运行; }
code() { curl -s -m 2 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

say "环境" "$( [ -d /opt/qqstack ] && echo '容器内' || echo '（未部署？）' )"
say "Xvfb"     "$(p Xvfb)"
say "x11vnc"   "$(p x11vnc)"
say "QQ"       "$(p qq)"
# QQ 登录成功后会在 ~/.config/QQ/<uin>/ 建目录 —— 这是"真的登上了"最直接的证据。
# 扫不到账号目录就说明还在扫码页，此时 OneBot 一定不会就绪，省得用户怀疑 hook。
QQ_UIN=""
for d in "${QQ_HOME:-/root}"/.config/QQ/[0-9]*; do
  [ -d "$d" ] && { QQ_UIN=$(basename "$d"); break; }
done
say "QQ 账号" "${QQ_UIN:-未登录（扫码后点一次「启动」）}"
say "hook 已加载" "$(for q in $(pgrep -x qq 2>/dev/null); do grep -qa snowluma-linux-arm64.so /proc/$q/maps 2>/dev/null && { echo 是; break; }; done)"
say "SnowLuma" "$(pgrep -f 'snowluma/nod[e]' >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
say "OneBot ${BOT_HTTP:-3000}" "$(code http://127.0.0.1:${BOT_HTTP:-3000}/)  (401/403=正常)"
say "OneBot ${BOT_WS:-3001}" "$(code http://127.0.0.1:${BOT_WS:-3001}/)  (426=正常)"
say "控制台 ${AGENT_PORT:-3081}" "$(code http://127.0.0.1:${AGENT_PORT:-3081}/)"
say "虚拟屏 ${NOVNC_PORT:-6081}" "$(code http://127.0.0.1:${NOVNC_PORT:-6081}/)"
echo
# 新版 Agent 没有 /api/status（那是旧 JS 版的接口），改用 /api/overview：
#   模型   → llm.defaultProvider / llm.defaultModel（旧的是 orchestrator.model）
#   OneBot → runtime.napcatConnected + runtime.onebot.connected（src/index.ts 里 runtime() 传入的），
#            账号信息是 runtime.selfId / runtime.nickname。字段拿不到就老实说"读不到"，不伪造。
curl -s -m 4 "http://127.0.0.1:${AGENT_PORT:-3081}/api/overview" 2>/dev/null | python3 -c "
import sys,json
url='http://127.0.0.1:${AGENT_PORT:-3081}'
try:
    d=json.load(sys.stdin)
    rt=d.get('runtime') or {}
    ob=rt.get('onebot') or {}
    conn=rt.get('napcatConnected', ob.get('connected', False))
    raw_acc=ob.get('accountReady')
    acc=None if raw_acc is None else bool(raw_acc)
    sid=rt.get('selfId') or 0
    nick=rt.get('nickname') or ''
    who='%s(%s)' % (nick, sid) if sid else (nick or '')
    print('OneBot :', '已连接' if conn else '未连接', who)
    # 未连接时把根因说清楚：光一句"未连接"用户没法自救，只能来回猜
    if not conn:
        if acc is False:
            print('  原因   :', '协议端没识别到账号（accountReady=false）')
            print('  建议   :', '点「启动」（会重启协议端+控制台，QQ 不用重新扫码）')
        elif acc is True:
            print('  原因   :', '账号已识别但 WebSocket 未连上（看 /tmp/qqagent.log）')
            print('  建议   :', '点「启动」（会重启协议端+控制台，QQ 不用重新扫码）')
    llm=d.get('llm') or {}
    prov=llm.get('defaultProvider') or ''
    model=llm.get('defaultModel') or ''
    m='/'.join(x for x in (prov, model) if x)
    print('模型   :', m or '(未配置 —— 到面板「模型接入」填 OpenAI 兼容的 API Key)')
except Exception:
    print('控制台未启动或状态读取失败 —— 面板：' + url + ' （日志：tail -50 /tmp/qqagent.log）')"
echo
echo "QQ 最近 hook 日志："
grep -a "slhook" /tmp/qq.log 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  （无）"
