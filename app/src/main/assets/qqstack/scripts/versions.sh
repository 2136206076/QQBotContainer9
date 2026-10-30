#!/bin/bash
# 版本体检：把每个组件的实际版本和"实测可用版本"对比，✗ 就是要处理的
# 用法：bash scripts/versions.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
QQ_DIR=${QQ_DIR:-/opt/QQ}; SNOWLUMA_DIR=${SNOWLUMA_DIR:-/opt/snowluma}; AGENT_DIR=${AGENT_DIR:-/opt/qqagent}
STACK_DIR=${STACK_DIR:-/opt/qqstack}
ok(){ printf '  \033[32m✓\033[0m %-26s %s\n' "$1" "$2"; }
bad(){ printf '  \033[31m✗\033[0m %-26s %s\n' "$1" "$2"; }
info(){ printf '  · %-26s %s\n' "$1" "$2"; }
echo "== 期望版本（实测可用组合）=="
echo "    QQ 3.2.32-52194 arm64  +  SnowLuma 2.1.1 linux-arm64  +  QQ Agent 0.4.0"
echo
echo "== 环境 =="
info "内核/架构" "$(uname -m) / $(uname -r)"
[ -f /etc/os-release ] && info "系统" "$(. /etc/os-release; echo "$PRETTY_NAME")"
if [ -d /opt/qqstack ] || [ -f /bin/bash ]; then
  ok "容器环境" "$(bash "$HERE/mkpath-alias.sh" --probe 2>/dev/null || echo 本机)"
else
  bad "容器环境" "未检测到 /opt/qqstack"
fi
info "可用内存" "$(free -m 2>/dev/null | awk '/Mem/{print $2" MB（已用 "$3" MB）"}' || echo '?')"
echo
echo "== 关键组件 =="
QV=$(python3 -c "import json;print(json.load(open('$QQ_DIR/resources/app/package.json'))['version'])" 2>/dev/null)
[ "$QV" = "3.2.32-52194" ] && ok "Linux 版 QQ" "$QV" || bad "Linux 版 QQ" "${QV:-未安装}（期望 3.2.32-52194）"
SV=$(python3 -c "import json;print(json.load(open('$SNOWLUMA_DIR/release.json'))['version'])" 2>/dev/null)
ST=$(python3 -c "import json;print(json.load(open('$SNOWLUMA_DIR/release.json'))['target'])" 2>/dev/null)
[ "$SV" = "2.1.1" ] && ok "SnowLuma" "$SV / $ST" || bad "SnowLuma" "${SV:-未安装}（期望 2.1.1 linux-arm64）"
AV=$(python3 -c "import json;print(json.load(open('$AGENT_DIR/package.json'))['version'])" 2>/dev/null)
[ -n "$AV" ] && ok "QQ Agent" "$AV" || bad "QQ Agent" "未安装（期望 0.4.0）"
NV=$("$SNOWLUMA_DIR/node" -v 2>/dev/null)
info "SnowLuma 自带 node" "${NV:-?}（期望 v24.22.1）"
SYSNV=$(node -v 2>/dev/null)
case "$SYSNV" in
  v2[0-9]*|v3[0-9]*) ok "系统 node（跑 Agent）" "$SYSNV（≥20 可以）" ;;
  *) bad "系统 node（跑 Agent）" "${SYSNV:-缺失}（需 ≥20，Ubuntu apt 默认 18，要换 NodeSource 22）" ;;
esac
# ---- 配对校验（重点）----
# 上面是逐项体检，这里做**联合判定**：QQ 和 SnowLuma 是硬配对的 —— 版本对不上
# 的表现是「进程都起来了、但 SnowLuma 永远 awaiting readiness」，而且不报任何错，
# 最难查。所以两个都必须同时是实测可用版本才算通过，缺一个就明确告诉用户该装哪个。
EXP_QQ="3.2.32-52194"; EXP_QQ_ARCH="arm64"
EXP_SL="2.1.1"; EXP_SLT="linux-arm64"
echo
echo "== QQ × SnowLuma 配对校验（关键）=="
info "实测可用组合" "QQ $EXP_QQ ($EXP_QQ_ARCH)  +  SnowLuma $EXP_SL ($EXP_SLT)"
# QQ 主程序的实际架构：直接读 ELF 头里的 e_machine，比看 deb 包名可靠
QQ_ARCH=$(python3 - "$QQ_DIR/qq" <<'PY' 2>/dev/null
import struct, sys
try:
    with open(sys.argv[1], "rb") as f:
        head = f.read(64)
    if head[:4] != b"\x7fELF":
        print("?")
    else:
        fmt = "<" if head[5] == 1 else ">"
        machine = struct.unpack_from(fmt + "H", head, 18)[0]
        print({183: "arm64", 62: "x86_64", 3: "x86"}.get(machine, "e_machine=%d" % machine))
except Exception:
    print("?")
PY
)
[ -n "$QQ_ARCH" ] || QQ_ARCH="?"
info "QQ 主程序架构" "$QQ_ARCH（期望 $EXP_QQ_ARCH）"
if [ "$QV" = "$EXP_QQ" ] && [ "$SV" = "$EXP_SL" ] && [ "$ST" = "$EXP_SLT" ] && [ "$QQ_ARCH" = "$EXP_QQ_ARCH" ]; then
  ok "配对结果" "✓ 一致 —— QQ $QV ($QQ_ARCH) × SnowLuma $SV ($ST)，可以放心跑 start-all.sh"
else
  bad "配对结果" "✗ 不配对 —— 这样即使全起来了，SnowLuma 也会一直 awaiting readiness 且无报错"
  [ "$QV" = "$EXP_QQ" ] || info "  ↳ 该装的 QQ" "$EXP_QQ（$EXP_QQ_ARCH）：QQ_3.2.32_*_arm64_01.deb / 当前是 ${QV:-未安装}"
  [ "$SV" = "$EXP_SL" ] && [ "$ST" = "$EXP_SLT" ] || \
    info "  ↳ 该装的 SnowLuma" "$EXP_SL（$EXP_SLT）：SnowLuma-v$EXP_SL-$EXP_SLT.tar.gz / 当前是 ${SV:-未安装} ${ST:-}"
  [ "$QQ_ARCH" = "$EXP_QQ_ARCH" ] || info "  ↳ 架构不对" "QQ 主程序是 $QQ_ARCH，请换 $EXP_QQ_ARCH 的包"
  info "  ↳ 换完再跑" "bash $HERE/versions.sh 复核 → bash $HERE/start-all.sh"
fi

# 这两个 .so 缺了都不用慌：一个能从 SnowLuma 主库里自动导出，一个是容器里现场编的。
# 所以「缺失」时不光打 ✗，还要直接把自愈命令指出来。
for f in libslhook.so libsnowluma_linux_resident_dispatch.so; do
  if [ -f "$STACK_DIR/$f" ]; then
    info "$f" "$(md5sum "$STACK_DIR/$f" | cut -d' ' -f1)"
    continue
  fi
  case "$f" in
    libsnowluma_linux_resident_dispatch.so)
      bad "$f" "缺失 → 可以自动导出，不用自己找二进制"
      info "  ↳ 现在就导出" "python3 $STACK_DIR/tools/extract-resident-dispatch.py"
      info "  ↳ 或跑一次诊断" "bash $HERE/slhook-diag.sh（它的第 0 步会自动补导出）"
      ;;
    libslhook.so)
      bad "$f" "缺失 → 它是容器里用 gcc 现编的，需要重跑部署第 4 步（[4/9] 用 gcc 编出 hook 载入器）"
      info "  ↳ 手动补编" "gcc -shared -fPIC -O2 -o $STACK_DIR/libslhook.so $HERE/../bin/slhook.c -ldl"
      ;;
    *) bad "$f" "缺失" ;;
  esac
done
[ -f "$SNOWLUMA_DIR/native/snowluma-linux-arm64.so" ] && info "hook 主 so" "$(md5sum "$SNOWLUMA_DIR/native/snowluma-linux-arm64.so" | cut -d' ' -f1)" || bad "hook 主 so" "缺失"
for pkg in xvfb x11vnc novnc websockify fluxbox imagemagick; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok" && info "包 $pkg" "已装" || bad "包 $pkg" "未装"
done
echo
echo "== QQ 热更新状态（重点）=="
VCFG=${QQ_HOME:-/root}/.config/QQ/versions/config.json
if [ -f "$VCFG" ]; then
python3 - "$VCFG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(f"  · 当前 baseVersion = {d.get('baseVersion')}   curVersion = {d.get('curVersion')}   readyVersion = {d.get('readyVersion') or '(空)'}")
PY
else
info "versions/config.json" "不存在（QQ 可能还没跑过）"
fi
STAGED=$(ls -d "${QQ_HOME:-/root}"/.config/QQ/versions/*-* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')
if [ -n "$STAGED" ]; then bad "已下载的新版本" "$STAGED → 必须删掉，否则会被升级"; else ok "已下载的新版本" "无"; fi
grep -q "qqpatch.gtimg.cn" /etc/hosts 2>/dev/null && ok "热更新域名已屏蔽" "qqpatch.gtimg.cn" || bad "热更新域名已屏蔽" "未屏蔽（跑 bash scripts/freeze-hotupdate.sh）"
echo
echo "== 运行态 =="
info "QQ 进程" "$(pgrep -c -x qq 2>/dev/null || echo 0) 个"
Q=$(pgrep -x qq 2>/dev/null | head -1)
[ -n "$Q" ] && { grep -qa snowluma-linux-arm64.so /proc/$Q/maps && ok "hook 已注入" "是" || bad "hook 已注入" "否"; }
info "OneBot ${BOT_HTTP:-3000}/${BOT_WS:-3001}" "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:${BOT_HTTP:-3000}/) / $(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:${BOT_WS:-3001}/)"
info "控制台 ${AGENT_PORT:-3210}" "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:${AGENT_PORT:-3210}/)"
echo
echo "注意：Android 的「幽灵进程杀手」在容器里查不到，请按文档用 adb 确认已关闭，"
echo "      否则 QQ（十几个子进程）会在后台被系统悄悄杀掉。"
