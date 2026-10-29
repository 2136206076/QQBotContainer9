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
grep -q installed-rootfs /proc/self/mounts 2>/dev/null && ok "proot 容器" "$(bash "$HERE/mkpath-alias.sh" --probe)" || bad "proot 容器" "未检测到 installed-rootfs（脚本要在 proot 的 Ubuntu 里跑）"
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
for f in libslhook.so libsnowluma_linux_resident_dispatch.so; do
  if [ -f "$STACK_DIR/$f" ]; then info "$f" "$(md5sum "$STACK_DIR/$f" | cut -d' ' -f1)"
  else bad "$f" "缺失"; fi
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
