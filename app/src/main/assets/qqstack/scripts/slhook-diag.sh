#!/bin/bash
# snowluma hook 诊断：确认「为什么注入后退回 stub、卡在 awaiting readiness」
# 用法：bash scripts/slhook-diag.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
Q="$(pgrep -x qq 2>/dev/null | head -1)"
echo "========== 1. 进程 =========="
echo "QQ 主进程: ${Q:-（没在跑）}"
[ -n "${Q:-}" ] && echo "hook 是否已装进这个进程:" && grep -a "snowluma-linux-arm64.so" /proc/$Q/maps 2>/dev/null | awk '{print "  "$6}' | sort -u
echo "========== 2. wrapper.node 的加载方式（关键） =========="
if [ -n "${Q:-}" ]; then
grep -a wrapper /proc/$Q/maps 2>/dev/null | awk '{print $6}' | sort -u | sed 's/^/  /'
echo "  —— 出现 /proc/self/fd/ 或 memfd: 表示"从内存加载"，出现磁盘路径表示"从磁盘加载""
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
if cat /proc/locks >/dev/null 2>&1; then echo "  ✓ 可读，不需要打 /proc/locks 补丁"
else echo "  ✗ 读不了（EACCES）→ python3 patch/patch_snowluma.py ${SNOWLUMA_DIR:-/opt/snowluma}/index.mjs"; fi
echo
echo "判读方法："
echo "  · 有 'resident dispatch <- ... (ok)'      → hook 完整，问题在 QQ 登录/账号识别"
echo "  · 有 'resident dispatch <- ... (失败原因)'  → 载荷路径或文件坏了，或第 3 步别名没建"
echo "  · 一行都没有                              → stub 压根没调 dlopen，用 SLHOOK_VERBOSE=1 重启 QQ"
echo "      在 deploy.env 里加 SLHOOK_VERBOSE=1，再 grep slhook /tmp/qq.log"
