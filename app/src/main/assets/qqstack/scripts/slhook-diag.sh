#!/bin/bash
# snowluma hook 诊断：确认「为什么注入后退回 stub、卡在 awaiting readiness」
# 用法：bash scripts/slhook-diag.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
Q="$(pgrep -x qq 2>/dev/null | head -1)"
echo "========== 0. 自愈：resident dispatch 载荷 =========="
# proot 下 memfd 版 dlopen 加载不了 → slhook.c 会改加载磁盘文件 $RESIDENT_SO，
# 而那个磁盘文件官方包不带。这里发现它缺、但 SnowLuma 主库在，就直接替你导出补全，
# 让用户点一次「hook 诊断」就能修好，不用再去找 bin/ 里的二进制。
EXTRACT_PY="$HERE/../tools/extract-resident-dispatch.py"
SRC_SO="${HOOK_SO:-${SNOWLUMA_DIR:-/opt/snowluma}/native/snowluma-linux-arm64.so}"
DST_SO="${RESIDENT_SO:-${STACK_DIR:-/opt/qqstack}/libsnowluma_linux_resident_dispatch.so}"
if [ ! -f "$DST_SO" ] && [ -f "$SRC_SO" ]; then
  echo "  ✗ 缺 $DST_SO —— 这正是 dlopen 报 No such file or directory、hook 退回 stub 的原因"
  if [ -f "$EXTRACT_PY" ] && command -v python3 >/dev/null 2>&1; then
    echo "  → 直接从 SnowLuma 主库里导出内嵌载荷："
    python3 "$EXTRACT_PY" --source "$SRC_SO" --target "$DST_SO" 2>&1 | sed 's/^/    /'
    extract_rc="${PIPESTATUS[0]}"
    if [ "$extract_rc" -eq 2 ]; then
      echo "  ✗ 载荷疑似不对（没匹配到 resident_dispatch 特征），脚本拒绝写出、没生成文件"
      echo "    → 多半是 SnowLuma 升级后换了内嵌方式；确认载荷没问题可加 --allow-unverified 强行导出"
    elif [ -f "$DST_SO" ]; then
      echo "  ✓ 已补好，重启 QQ 让 hook 重装：bash $HERE/stop-all.sh && bash $HERE/start-all.sh"
    else
      echo "  ✗ 还是没生成，把上面的报错发出来"
    fi
  else
    echo "  ✗ 缺 $EXTRACT_PY 或容器里没有 python3，没法自动导出"
  fi
elif [ ! -f "$SRC_SO" ]; then
  echo "  · SnowLuma 主库还没装（$SRC_SO），跳过"
else
  echo "  · $DST_SO 已在，跳过（要强制重导：python3 $EXTRACT_PY --force）"
fi
echo "========== 1. 进程 =========="
echo "QQ 主进程: ${Q:-（没在跑）}"
[ -n "${Q:-}" ] && echo "hook 是否已装进这个进程:" && grep -a "snowluma-linux-arm64.so" /proc/$Q/maps 2>/dev/null | awk '{print "  "$6}' | sort -u
echo "========== 2. wrapper.node 的加载方式（关键） =========="
# 以前只查 $Q（主进程）一个 pid —— QQ 是多进程的，wrapper.node 往往由别的子进程加载，
# 只盯主进程就会看到"一片空白"，误判成 hook 没生效。这里扫全部 qq 进程，逐个报告。
if pgrep -x qq >/dev/null 2>&1; then
FOUND_WRAPPER=0
for p in $(pgrep -x qq 2>/dev/null); do
  W=$(grep -a "wrapper.node" /proc/$p/maps 2>/dev/null | awk '{print $6}' | sort -u)
  if [ -n "$W" ]; then
    echo "  ✓ pid=$p 已加载 wrapper.node:"
    echo "$W" | sed 's/^/      /'
    FOUND_WRAPPER=1
  fi
done
if [ "$FOUND_WRAPPER" = "0" ]; then
  echo "  ✗ 所有 $(pgrep -x qq 2>/dev/null | wc -l) 个 QQ 进程都**没有**加载 wrapper.node"
  echo "    → hook 还在 'waiting wrapper.node'，SnowLuma 拿不到数据，OneBot 永远不会就绪"
  echo "    → 先确认 QQ 是否真的登录成功（看下面的「QQ 登录态」），再点「启动」重试"
else
  echo "  —— 出现 /proc/self/fd/ 或 memfd: 表示从内存加载，出现磁盘路径表示从磁盘加载"
fi
else
echo "  （QQ 没跑，跳过）"
fi
echo "========== 3. 路径别名（Termux proot 特有）=========="
UB="$(bash "$HERE/mkpath-alias.sh" --probe)"
echo "  宿主 rootfs 前缀: $UB"
for x in opt/QQ/qq opt/snowluma/native/snowluma-linux-arm64.so opt/qqstack/libsnowluma_linux_resident_dispatch.so; do
  [ -e "$UB/$x" ] && echo "  ✓ $UB/$x" || echo "  ✗ $UB/$x （别名没建好 → hook 打不开文件）"
done
echo "========== 4. 文件校验 =========="
for f in "${LOADER_SO:-/opt/qqstack/libslhook.so}" "${RESIDENT_SO:-/opt/qqstack/libsnowluma_linux_resident_dispatch.so}" "${HOOK_SO:-/opt/snowluma/native/snowluma-linux-arm64.so}"; do
[ -f "$f" ] && printf "  %-58s %s\n" "$f" "$(md5sum "$f" | cut -d' ' -f1)" || echo "  缺 $f"
done
echo "  libslhook.so 是否包含 dlopen 拦截符号:"
nm -D --defined-only "${LOADER_SO:-/opt/qqstack/libslhook.so}" 2>/dev/null | grep -w dlopen | sed 's/^/    /' || echo "    (没找到 —— 这不是带 dlopen 拦截的版本)"
echo "========== 5. resident dispatch 载荷是否完好 =========="
R="${RESIDENT_SO:-/opt/qqstack/libsnowluma_linux_resident_dispatch.so}"
if [ -f "$R" ]; then
readelf -h "$R" 2>/dev/null | grep -E "Class|Machine" | sed 's/^/  /'
readelf -d "$R" 2>/dev/null | grep SONAME | sed 's/^/  /'
nm -D --defined-only "$R" 2>/dev/null | grep nnp_resident_dispatch | sed 's/^/  /'
else
echo "  缺 $R"
fi
echo "========== 6. 最近一次启动日志里的 hook 行为 =========="
for L in /tmp/qq.log /tmp/qq-preload.log /tmp/qq_v2.log; do
[ -f "$L" ] && echo "  --- $L" && grep -a "slhook" "$L" | tail -8 | sed 's/^/    /'
done
echo "========== 7. /proc/locks 能不能读（账号识别）=========="
PATCH_PY="$HERE/../patch/patch_snowluma.py"
if cat /proc/locks >/dev/null 2>&1; then
  echo "  ✓ /proc/locks 可读 —— 按设计**不打** /proc/locks 兜底补丁，不改动任何文件"
  echo "    → 如果 SnowLuma 仍报 EACCES /proc/locks，请加 --force 重跑："
  echo "      python3 $PATCH_PY ${SNOWLUMA_DIR:-/opt/snowluma}/index.mjs --force"
else
  echo "  ✗ 读不了（EACCES）→ python3 $PATCH_PY ${SNOWLUMA_DIR:-/opt/snowluma}/index.mjs"
fi
echo "  —— 上一次补丁实际走的是哪条路（看标记文件最省事）："
MF="${STACK_DIR:-/opt/qqstack}/.locks-patch-method"
if [ -f "$MF" ]; then
  sed 's/^/     /' "$MF"
  m=$(sed -n 's/^method=//p' "$MF" 2>/dev/null | head -1)
  if [ "$m" = "B" ]; then
    echo "     ⚠ 这是降级方案：补丁打上了，但精度不如方案 A，且替身文件有时效性"
    echo "       ↳ 建议核对 SnowLuma 版本（应与 QQ 3.2.32-52194 配对的 2.1.1）后重打方案 A"
  fi
else
  echo "     （没有标记文件 $MF —— 还没跑过补丁脚本）"
fi
echo "  —— 补丁脚本退出码：0=正常（方案 A 成功 / 已打过跳过 / 按设计不用打）；"
echo "                     3=⚠ 降级到方案 B（替身文件兜底），属降级成功，别中断部署但要看一眼；"
echo "                     其它=失败"
echo "========== 8. 账号识别与 OneBot 连接 =========="
# a) QQ 登录态：QQ 登录成功后会在 ~/.config/QQ/<uin>/ 建目录，这是"真的登上了"最直接的证据
QH="${QQ_HOME:-/root}"
QQ_UIN=""
for d in "$QH"/.config/QQ/[0-9]*; do
[ -d "$d" ] && { QQ_UIN="$QQ_UIN $(basename "$d")"; }
done
if [ -n "$QQ_UIN" ]; then
for u in $QQ_UIN; do echo "  ✓ QQ 账号 $u（已登录）"; done
else
echo "  ✗ 没找到账号目录 —— QQ 还没真正登录（去「扫码登录」里扫码）"
fi
# b) 协议端只是在监听 ≠ 账号就绪：401/403 是鉴权中间件在挡，跟账号识别无关
C3000="$(curl -s -m 3 "http://127.0.0.1:${BOT_HTTP:-3000}/" -o /dev/null -w '%{http_code}' 2>/dev/null)"
echo "  · 协议端 ${BOT_HTTP:-3000} → HTTP ${C3000:-无响应}（401/403 只说明服务在监听，不代表账号已识别）"
# c) Agent 侧的真实连接态：原版 qq-agent 没有 /api/overview（上一版 TypeScript 分支才有），
#    用它自带的 /api/onebot/groups 判：200=真取到了群列表（连上）、502=没连上（body 里带原因）。
#    -o 落盘再用 python 读，避免把 curl 的输出和状态码混在一起解析。
OB_CODE="$(curl -s -m 5 -o /tmp/.ob-diag.json -w '%{http_code}' "http://127.0.0.1:${AGENT_PORT:-3081}/api/onebot/groups" 2>/dev/null || true)"
case "$OB_CODE" in
  200)
    echo "  ✓ OneBot 已连接（能取到群列表）"
    ;;
  502)
    echo "  ✗ OneBot 未连接"
    python3 -c "import json;d=json.load(open('/tmp/.ob-diag.json'));print('    原因: ' + str(d.get('error') or '（/api/onebot/groups 没给 error 字段）'))" 2>/dev/null \
      || echo "    原因: （读不出 /tmp/.ob-diag.json）"
    echo "    → 协议端没起 / 端口不对 / token 不对，看 /tmp/qqagent.log"
    ;;
  *)
    echo "  ? 控制台没响应（HTTP ${OB_CODE:-000}）—— 控制台没起？看 /tmp/qqagent.log"
    ;;
esac
# d) 核对控制台侧的 OneBot 目标地址：连不上最常见的原因就是它指向了错的端口 / 带了错的 token。
#    /api/config 走 sanitizeConfig：密钥字段（accessToken）会被**整个删掉**、只留
#    hasAccessToken 布尔 —— 所以这里读 hasAccessToken（读 accessToken 会永远是"空"）。
#    绝不打印 token 明文：诊断输出经常被截图发出去。万一变体回了明文，也只打长度。
#    临时文件用 -diag 后缀：status.sh 也用 /tmp/.agent-conf.json，两边并发（用户点了
#    「状态」又来点「hook 诊断」）会互相覆盖，谁先写完谁被对方读成半截/别人的内容。
CONF_CODE="$(curl -s -m 5 -o /tmp/.agent-conf-diag.json -w '%{http_code}' "http://127.0.0.1:${AGENT_PORT:-3081}/api/config" 2>/dev/null || true)"
if [ "$CONF_CODE" = "200" ]; then
  python3 -c "import json;d=json.load(open('/tmp/.agent-conf-diag.json'));ob=d.get('onebot') or {};u=ob.get('wsUrl') or '';h=ob.get('httpUrl') or '';t=ob.get('accessToken');ht=ob.get('hasAccessToken');print('  · onebot.wsUrl       = ' + (u or '(空)'));print('  · onebot.httpUrl     = ' + (h or '(空)'));print('  · onebot.accessToken = ' + (('已设置（长度 %d，不显示明文）' % len(t)) if isinstance(t,str) and t else ('已设置（服务端只回 hasAccessToken=true，不返回明文）' if ht is True else '空（未设置）')));print('  → 期望指向 127.0.0.1:3001（WS）/ 127.0.0.1:3000（HTTP）；不一致就改 /opt/qqagent/data/config.json 后点「启动」')" 2>/dev/null \
    || echo "  · /api/config 不是 JSON —— 控制台可能没起来"
else
  echo "  · /api/config 取不到（HTTP ${CONF_CODE:-000}）—— 控制台没起？日志：tail -20 /tmp/qqagent.log"
fi
# e) 两端日志尾巴：一眼就能看出 SnowLuma 是停在 awaiting readiness 还是真的没扫到账号
for L in /tmp/snowluma.log /tmp/qqagent.log; do
[ -f "$L" ] || continue
echo "  --- $L (tail -8)"
tail -8 "$L" | sed 's/^/    /'
done
echo
echo "判读方法："
echo "  · 第 0 步说「缺 …」又被补回来了     → 已自愈，重跑 start-all.sh 让 QQ 装上 hook"
echo "  · 有 'resident dispatch <- ... (ok)'      → hook 完整，问题在 QQ 登录/账号识别"
echo "  · 有 'resident dispatch <- ... (失败原因)'  → 载荷路径或文件坏了，或第 3 步别名没建"
echo "  · 一行都没有                              → stub 压根没调 dlopen，用 SLHOOK_VERBOSE=1 重启 QQ"
echo "      在 deploy.env 里加 SLHOOK_VERBOSE=1，再 grep slhook /tmp/qq.log"
echo "  · 第 2 步说「所有进程都没加载 wrapper.node」 → QQ 没真正登录完，或 wrapper 未加载，先看第 8 步的登录态"
echo "  · 第 8 步「OneBot 未连接」但 QQ 账号已登录 → 协议端没扫到账号，点「启动」即可（会自动重启协议端）"
