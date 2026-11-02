#!/bin/bash
# 锁定 QQ 版本：把 /opt/QQ 递归设为只读，linuxqq 的自动更新器即便把新包下载下来，
# 也因为无法覆盖写入而失效，版本被永久钉死。
#
# 为什么不用「改配置 / 拦域名」：
# 1) linuxqq NT 的更新逻辑焊死在加密的 application.asar / major.node 里（已从 deb 提取验证：
#    明文里只能扫到 qun.qq.com / im.qq.com / qqpatch.gtimg.cn 等功能性域名，没有任何明文更新主机）；
# 2) 按主机名拦不可靠，且 dldir1.qq.com 之类兼做文件传输 CDN，误拦会搞挂正常收发文件。
# 文件系统层锁版本是主机无关的、确定性的解法。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"
QQ_DIR="${QQ_DIR:-/opt/QQ}"

say(){ echo "[pin-qq] $*"; }

if [ ! -d "$QQ_DIR" ]; then
  say "$QQ_DIR 不存在，跳过（QQ 还没装）"
  exit 0
fi

# 递归去掉所有写权限：文件 644 -> 444，目录 755 -> 555。
# 目录仍保留 r-x（可遍历），可执行文件仍保留 r-x（可运行），QQ 正常运行不受影响；
# 但任何进程（含更新器）都无法再向 /opt/QQ 写入或新建文件，更新自然失效。
chmod -R a-w "$QQ_DIR" 2>/dev/null
# 兜底：确保目录可遍历、关键可执行文件保持可执行（a-w 已保留 x，这里防极端 umask 情形）
find "$QQ_DIR" -type d -exec chmod a+x {} + 2>/dev/null
for b in qq chrome-sandbox chrome_crashpad_handler; do
  [ -f "$QQ_DIR/$b" ] && chmod a+x "$QQ_DIR/$b" 2>/dev/null
done
say "已锁定 $QQ_DIR 为只读（版本钉死，linuxqq 自动更新无法覆盖）"

# 清理可能正在途的更新临时文件（best-effort，不动用户数据）
rm -rf /tmp/QQ*update* /tmp/qq-update* 2>/dev/null || true
# 杀掉仍在跑的更新子进程（按命令行特征，避免误杀主程序）
pkill -f 'opt/QQ.*--update' 2>/dev/null || true
pkill -f 'opt/QQ/resources/app.*update' 2>/dev/null || true
exit 0
