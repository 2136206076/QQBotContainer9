#!/usr/bin/env bash
# 修复这两次云端编译报的 Kotlin 错误（幂等，可反复跑）
#   1) CrashHandler.kt 引用 QQBotApp，但 QQBotApp.kt 里类名写成了 App（且与 object App 重名）
#   2) Installer.kt 里 bash 变量 $SRC/$PKG 没转义，Kotlin 当成自己的模板变量
# 用法：bash tools/fix-build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

say(){ printf '\n\033[36m== %s\033[0m\n' "$*"; }
say "1/3 修 QQBotApp 类名"
python3 - <<'PY'
p = 'app/src/main/java/com/yuanbao/qqbot/QQBotApp.kt'
s = open(p).read()
if 'class QQBotApp' not in s:
    s = s.replace('class App : Application()', 'class QQBotApp : Application()')
    open(p, 'w').write(s)
print('  ✓', 'class QQBotApp : Application()' if 'class QQBotApp' in s else '✗ 没改到')
PY

say "2/3 重写 Installer.kt 的 QQ 安装段（去掉 bash 变量）"
python3 - <<'PY'
p = 'app/src/main/java/com/yuanbao/qqbot/Installer.kt'
s = open(p).read()
import re as _re
def has_bash_var(t):
    for m in _re.finditer(r'"""', t):
        e = t.find('"""', m.end())
        if e < 0: break
        if _re.search(r'\$[A-Z][A-Z0-9_]{2,}\b', t[m.end():e]): return True
    return False
if has_bash_var(s):
    start = s.index('    private fun installFromSource(ctx: Context, src: String): Boolean {')
    end = s.index('    fun patchAndFinish(ctx: Context) {')
    new = '''    private fun installFromSource(ctx: Context, src: String): Boolean {
        // 全部用 Kotlin 插值，脚本里不再出现 bash 变量，避免 $ 被 Kotlin 当成模板
        val pkg = if (src.startsWith("http")) "/tmp/qq.pkg" else src
        val dl  = if (src.startsWith("http"))
            "curl -sL -o '$pkg' '$src' || { echo '下载失败'; exit 1; }" else ""
        val script = """
            set -e
            cd /tmp
            $dl
            [ -f '$pkg' ] || { echo "文件不存在: $pkg"; exit 1; }
            mkdir -p /opt
            case '$pkg' in
              *.deb)           dpkg -i '$pkg' 2>&1 | tail -3 || apt-get install -y -f 2>&1 | tail -3 ;;
              *.tar.gz|*.tgz)  tar xzf '$pkg' -C /opt ;;
              *.tar.xz)        tar xJf '$pkg' -C /opt ;;
              *)               echo "不认识的包格式: $pkg"; exit 1 ;;
            esac
            chmod +x /opt/QQ/qq /opt/QQ/chrome-sandbox 2>/dev/null
            echo "QQ: $(python3 -c "import json;print(json.load(open('/opt/QQ/resources/app/package.json'))['version'])" 2>/dev/null)"
        """.trimIndent()
        val rc = Proot.run(ctx, script, tag = "qq")
        if (rc != 0) LogBus.log("✗ QQ 安装失败($rc)。请确认包是 3.2.32 arm64 的 deb/tar.gz")
        return rc == 0
    }

'''
    s = s[:start] + new + s[end:]
    open(p, 'w').write(s)
    print('  ✓ installFromSource 已重写')
else:
    print('  · 已经是新版，跳过')
PY

say "3/3 检查 raw string 里还有没有「Kotlin 里没定义」的 bash 变量"
python3 - <<'PY'
import re, glob
# 只查形如 $ALL_CAPS 的（bash 变量习惯大写；Kotlin 局部变量都是小写/驼峰）
bad = []
for f in sorted(glob.glob('app/src/main/java/com/yuanbao/qqbot/*.kt')):
    src = open(f).read()
    for m in re.finditer(r'"""', src):
        end = src.find('"""', m.end())
        if end < 0: break
        block = src[m.end():end]
        for mm in re.finditer(r'\$[A-Z][A-Z0-9_]{1,}\b', block):
            ln = src[:m.end()].count('\n') + block[:mm.start()].count('\n') + 1
            bad.append(f'{f}:{ln}  {mm.group(0)}')
if bad:
    print('  ✗ 还有可疑的大写 bash 变量：')
    for b in bad: print('    ', b)
else:
    print('  ✓ 干净（raw string 里没有大写裸变量）')
PY
printf '\n\033[32m✓ 修复完成，可以推送了\033[0m\n'
