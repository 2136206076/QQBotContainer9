#!/usr/bin/env bash
# 真·一条命令：找新包 → 建/连仓库 → 拷进去 → 自动修 → 推送 → 触发编译
#
# 用法（Termux 里，新 zip 已解压到 ~/QQBotContainer）：
#     bash ~/QQBotContainer/tools/one-shot.sh
# 指定仓库名：
#     bash ~/QQBotContainer/tools/one-shot.sh QQBotContainer9
set -uo pipefail

REPO=${1:-QQBotContainer9}
EMAIL=2136206076@users.noreply.github.com
say(){ printf '\n\033[36m== %s\033[0m\n' "$*"; }
die(){ printf '\n\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

say "1/6 找新解压的源目录"
# 优先用脚本自身位置反推；找不到再按名字扫
SELF=$(cd "$(dirname "$0")/.." && pwd)
if [ -d "$SELF/app" ] && [ -f "$SELF/app/build.gradle" ]; then
  SRC=$SELF
else
  SRC=$(find "$HOME" -maxdepth 4 -path "*QQBotContainer/app/build.gradle" 2>/dev/null | head -1)
  SRC=${SRC%/app/build.gradle}
fi
[ -n "$SRC" ] && [ -f "$SRC/app/build.gradle" ] || die "找不到新工程。请先解压：cd ~ && unzip -q QQBotContainer.zip"
echo "  ✓ $SRC"

say "2/6 检查 gh 登录"
command -v gh >/dev/null || die "没装 gh：pkg install gh"
gh auth status >/dev/null 2>&1 || { echo "  需要登录…"; gh auth login --web --git-protocol https || die "登录失败"; }
USER=$(gh api user --jq .login 2>/dev/null) || die "登录态有问题"
echo "  ✓ $USER"

say "3/6 准备仓库 $REPO"
gh repo view "$USER/$REPO" >/dev/null 2>&1 || {
  echo "  仓库不存在，创建…"
  gh repo create "$REPO" --public >/dev/null 2>&1 || die "建仓库失败：gh repo create $REPO --public"
}
cd ~ && rm -rf QQBotPush
git clone "https://github.com/$USER/$REPO.git" QQBotPush 2>&1 | tail -2 || die "clone 失败（网络？）"
cd ~/QQBotPush || die "进不去仓库目录"

say "4/6 用新工程整体替换旧内容"
rm -rf app tools docs .github README.md build.gradle settings.gradle gradle.properties
cp -r "$SRC/app" "$SRC/tools" "$SRC/docs" "$SRC/.github" "$SRC/README.md" \
      "$SRC/build.gradle" "$SRC/settings.gradle" "$SRC/gradle.properties" . 2>/dev/null
[ -f app/build.gradle ] || die "拷贝失败"
echo "  ✓ $(find app tools .github -type f 2>/dev/null | wc -l) 个文件就位"

say "5/6 自动修（移除 QQBotApp 依赖 + 转义 bash 变量）"
cp "$SRC/tools/fix-and-push.sh" tools/ 2>/dev/null
bash tools/fix-and-push.sh 2>&1 | grep -E "^  ✓|^  ✗|^  ·|== [0-9]" | head -20

say "6/6 完成"
git remote get-url origin 2>/dev/null | sed 's|\.git$|/actions|' | xargs -I{} echo "  进度：{}"
echo "  等 5~8 分钟，绿了进那次运行 → 拉到底部 Artifacts → QQBotContainer-debug"
