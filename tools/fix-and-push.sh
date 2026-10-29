#!/data/data/com.termux/files/usr/bin/bash
# 一键修复 + 推送（不用知道工程在哪，脚本自己找）
# 用法：把本文件内容整段复制到 Termux 粘贴执行即可
set -e

D=$(find "$HOME" -maxdepth 4 -type d -name QQBotContainer 2>/dev/null | head -1)
if [ -z "$D" ]; then
  echo "✗ 没找到 QQBotContainer 目录"
  echo "  如果你知道它在哪，告诉我路径；或者重新解压一次工程包到 ~/"
  exit 1
fi
echo "✓ 工程目录：$D"
cd "$D"

F=app/src/main/java/com/yuanbao/qqbot/Installer.kt
if [ ! -f "$F" ]; then echo "✗ 目录不对，没有 $F"; exit 1; fi

# 把 bash 变量 $SRC/$PKG 转义成 Kotlin 能原样输出的形式
sed -i "s/\$SRC/\${'\$'}SRC/g; s/\$PKG/\${'\$'}PKG/g" "$F"
echo "--- 改后这几行应显示 \${'\$'}SRC / \${'\$'}PKG ---"
grep -n "SRC\|PKG" "$F" | head -8
echo

git add -A
git commit -m "fix: escape bash vars in Kotlin raw string" || echo "（没有改动可提交）"
git push
echo
echo "✓ 推送完成。现在去浏览器看："
echo "  $(gh repo view --json url -q .url 2>/dev/null || echo 'github.com/你的用户名/QQBotContainer')/actions"
