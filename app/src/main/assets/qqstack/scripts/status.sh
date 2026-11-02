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

# 控制台跑没跑：原版 qq-agent 的首页是 /，200 就说明进程活着（静态页 + API 同一个 HTTP 服务）。
# 不看进程名：proot 里 pgrep 容易命中马甲 shell，HTTP 码才是"真的能服务"的证据。
AG_PORT="${AGENT_PORT:-3081}"
AG_CODE="$(code "http://127.0.0.1:$AG_PORT/")"
case "$AG_CODE" in
  200)     say "控制台 $AG_PORT" "运行中（HTTP 200）" ;;
  000|"")  say "控制台 $AG_PORT" "未运行" ;;
  *)       say "控制台 $AG_PORT" "HTTP $AG_CODE（进程在但没给 200，看 tail -50 /tmp/qqagent.log）" ;;
esac
say "虚拟屏 ${NOVNC_PORT:-6081}" "$(code http://127.0.0.1:${NOVNC_PORT:-6081}/)"
echo
# 原版 qq-agent 没有 /api/overview（那是上一版 TypeScript 分支的接口，已弃用），
# OneBot 连接态只能看 /api/onebot/groups 的 HTTP 码：
#   200 → 已连接（真取到了群列表）
#   502 → 控制台活着但没连上，body 里有 error 字段说明原因
#   其它（000 / 超时）→ 控制台没响应
# 控制台没跑时整块不打印：进程都没起来，说"未连接"只会误导排查方向。
if [ "$AG_CODE" != "200" ]; then
  echo "控制台未启动或状态读取失败 —— 面板：http://127.0.0.1:$AG_PORT （日志：tail -50 /tmp/qqagent.log）"
else
  OB_CODE="$(curl -s -m 5 -o /tmp/.ob.json -w '%{http_code}' "http://127.0.0.1:$AG_PORT/api/onebot/groups" 2>/dev/null || true)"
  case "$OB_CODE" in
    200) say "OneBot 连接" "已连接" ;;
    502) say "OneBot 连接" "未连接"
         # error 字段用 python3 取：容器里不一定装了 jq，而 python3 是部署的硬依赖
         python3 -c "import json;d=json.load(open('/tmp/.ob.json'));print('  原因   :', (d.get('error') or '（/api/onebot/groups 没给 error 字段）'))" 2>/dev/null \
           || echo "  原因   : （读不出 /tmp/.ob.json）"
         echo "  建议   : 协议端没起 / 端口不对 / token 不对 —— 点「启动」（会重启协议端+控制台，QQ 不用重新扫码）" ;;
    *)   say "OneBot 连接" "控制台没响应（HTTP ${OB_CODE:-000}）" ;;
  esac
  # 模型接入：原版的 /api/config 走 sanitizeConfig —— 任何密钥字段（apiKey/accessToken…）
  # 会被**整个删掉**、只回一个 hasApiKey 布尔，所以这里读 hasApiKey，不能读 apiKey
  # （读不到 → 会永远显示"未填写"）。即便哪天变体把明文回出来了，也只打印长度，不打明文。
  curl -s -m 4 -o /tmp/.agent-conf.json "http://127.0.0.1:$AG_PORT/api/config" 2>/dev/null
  python3 -c "import json;d=json.load(open('/tmp/.agent-conf.json'));a=d.get('api') or {};m=a.get('model') or '';b=a.get('baseUrl') or '';k=a.get('apiKey');hk=a.get('hasApiKey');print('模型   :', ((m + '  @ ' + b) if m else '(未配置 —— 到面板「模型接入」填 OpenAI 兼容的 API Key)'));print('API Key:', (('已设置（长度 %d）' % len(k)) if isinstance(k,str) and k else ('已设置（服务端只回 hasApiKey=true，不返回明文）' if hk is True else '未填写')))" 2>/dev/null \
    || echo "模型   : （/api/config 读取失败）"
fi
echo
echo "QQ 最近 hook 日志："
grep -a "slhook" /tmp/qq.log 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  （无）"
