#!/usr/bin/env bash
# 一键：修复已知编译错误 → 提交 → 推送（当前目录必须是 git 仓库）
#
# 修的两类问题：
#   1) Kotlin raw string 里的 bash 变量（$SRC / $PKG 之类）会被当成字符串模板 → Unresolved reference
#   2) 跨文件引用了不存在的类 → Unresolved reference
# 幂等：修过再跑会提示"已是新版"。
#
# 用法：bash tools/fix-and-push.sh
set -uo pipefail
cd "$(dirname "$0")/.."

say(){ printf '\n\033[36m== %s\033[0m\n' "$*"; }

say "0/4 确认在 git 仓库里"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "✗ 当前不是 git 仓库。请先 clone："
  echo "    cd ~ && rm -rf QQBotPush && git clone https://github.com/<你的用户名>/<仓库>.git QQBotPush && cd QQBotPush"
  echo "    然后把新工程文件拷进来（rm -rf app tools .github 再 cp -r）"
  exit 1
}
echo "  ✓ $(git rev-parse --abbrev-ref HEAD)  $(git remote get-url origin 2>/dev/null)"

say "1/4 清除对已删除类的引用（QQBotApp）"
rm -f app/src/main/java/com/yuanbao/qqbot/QQBotApp.kt
python3 - <<'PY'
import re, glob
p = 'app/src/main/AndroidManifest.xml'
s = open(p).read()
s = s.replace('        android:name=".QQBotApp"\n', '')
open(p, 'w').write(s)

# CrashHandler 若还在引用 QQBotApp，就地改成自包含写法
p = 'app/src/main/java/com/yuanbao/qqbot/CrashHandler.kt'
s = open(p).read()
if 'QQBotApp' in s:
    s = s.replace('QQBotApp.ctx', 'ctxRef')
    s = s.replace('object CrashHandler {', 'object CrashHandler {\n\n    @Volatile\n    var ctxRef: android.content.Context? = null\n')
    open(p, 'w').write(s)
    print('  ✓ CrashHandler 已去 QQBotApp 依赖')
else:
    print('  · 无 QQBotApp 引用，跳过')
PY

say "2/4 修 raw string 里的 bash 变量"
python3 - <<'PY'
import re, glob
pat = re.compile(r'\$[A-Z][A-Z0-9_]{2,}\b')
changed = []
for f in sorted(glob.glob('app/src/main/java/com/yuanbao/qqbot/*.kt')):
    s = open(f).read()
    hit = False
    for m in re.finditer(r'"""', s):
        e = s.find('"""', m.end())
        if e < 0: break
        if pat.search(s[m.end():e]): hit = True; break
    if not hit: continue
    # 有 bash 变量 → 把该函数里所有 $XXX 替换成 ${'$'}XXX（Kotlin 原样输出 $）
    s2 = pat.sub(lambda mm: "${'$'}" + mm.group(0)[1:], s)
    open(f, 'w').write(s2)
    changed.append(f)
if changed:
    for c in changed: print('  ✓ 已转义：', c)
else:
    print('  · 干净，无需修改')
PY

say "3/4 再次自检"
python3 - <<'PY'
import re, glob
pat = re.compile(r'\$[A-Z][A-Z0-9_]{2,}\b')
bad = []
for f in sorted(glob.glob('app/src/main/java/com/yuanbao/qqbot/*.kt')):
    s = open(f).read()
    for m in re.finditer(r'"""', s):
        e = s.find('"""', m.end())
        if e < 0: break
        blk = s[m.end():e]
        for mm in pat.finditer(blk):
            ln = s[:m.end()].count('\n') + blk[:mm.start()].count('\n') + 1
            bad.append(f'{f}:{ln} {mm.group(0)}')
print('  ' + ('✗ 仍有：' + ', '.join(bad) if bad else '✓ raw string 无大写裸变量'))
import os
if os.path.exists('app/src/main/java/com/yuanbao/qqbot/QQBotApp.kt'):
    print('  ✗ QQBotApp.kt 还在')
else:
    print('  ✓ QQBotApp.kt 已移除')
PY

say "4/4 提交并推送"
EMAIL=2136206076@users.noreply.github.com
git add -A
git -c user.email="$EMAIL" -c user.name="$EMAIL" commit -m "fix: 移除 QQBotApp 依赖 + 转义 bash 变量" \
  || echo "  （无改动可提交）"
git push 2>&1 | tail -6
printf '\n\033[32m✓ 完成。去 Actions 页面等 5~8 分钟：\033[0m\n'
git remote get-url origin 2>/dev/null | sed 's|\.git$|/actions|'
