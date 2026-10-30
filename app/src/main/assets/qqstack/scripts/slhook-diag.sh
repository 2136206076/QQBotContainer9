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
echo
echo "判读方法："
echo "  · 第 0 步说「缺 …」又被补回来了     → 已自愈，重跑 start-all.sh 让 QQ 装上 hook"
echo "  · 有 'resident dispatch <- ... (ok)'      → hook 完整，问题在 QQ 登录/账号识别"
echo "  · 有 'resident dispatch <- ... (失败原因)'  → 载荷路径或文件坏了，或第 3 步别名没建"
echo "  · 一行都没有                              → stub 压根没调 dlopen，用 SLHOOK_VERBOSE=1 重启 QQ"
echo "      在 deploy.env 里加 SLHOOK_VERBOSE=1，再 grep slhook /tmp/qq.log"
