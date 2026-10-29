#!/data/data/com.termux/files/usr/bin/bash
# 全新仓库一键部署：本地重新 init → 建 GitHub 新仓库 → 推送 → 触发云端编译
#
# 为什么要新仓库：旧仓库里混着根目录的 build-apk.yml（GitHub 不会执行它，但容易混淆），
# 而且 .git 丢过一次。新仓库从零开始，最干净。
#
# 用法（Termux 里）：
#   bash tools/new-repo.sh                    # 仓库名默认 QQBotContainer2，被占用会自动加后缀重试
#   bash tools/new-repo.sh MyBotName          # 自定义仓库名
set -uo pipefail

EMAIL=${EMAIL:-2136206076@users.noreply.github.com}
BASE=${1:-QQBotContainer2}

say() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

# ---------- 0. 前置检查 ----------
say "0/6 检查 gh 登录状态"
command -v gh >/dev/null || die "没装 gh：pkg install gh"
if ! gh auth status >/dev/null 2>&1; then
  echo "  ⚠ 未登录 / 登录态过期，重新登录："
  echo "    浏览器打开它给的链接，填验证码，授权"
  gh auth login --web --git-protocol https || die "登录失败"
fi
USER=$(gh api user --jq .login 2>/dev/null) || die "拿不到 GitHub 用户名，登录态有问题"
echo "  ✓ 已登录：$USER"

say "1/6 定位工程目录"
CFG=$(find "$HOME" -maxdepth 5 -path "*/.github/workflows/build-apk.yml" 2>/dev/null | head -1)
[ -n "$CFG" ] || die "没找到工程（应在 ~/ 下某个含 .github/workflows/build-apk.yml 的目录）"
D=${CFG%/.github/workflows/build-apk.yml}
echo "  · $D"
cd "$D"

say "2/6 转义修复（幂等）"
python3 - <<'PY'
p = 'app/src/main/java/com/yuanbao/qqbot/Installer.kt'
s = open(p).read()
s = s.replace('$SRC', "${'$'}SRC").replace('$PKG', "${'$'}PKG")
open(p, 'w').write(s)
print('  ✓ Installer.kt 已修复')
PY

say "3/6 全新 git 仓库（不复用旧的 .git）"
rm -rf .git
git init -q
git branch -M main
git add -A
git -c user.email="$EMAIL" -c user.name="$USER" commit -q -m "QQBotContainer: 手机端 QQ 机器人容器 App" \
  || die "提交失败（工程目录可能是空的？）"
echo "  ✓ $(git log --oneline -1)"

say "4/6 建 GitHub 仓库并推送（名字被占用会自动换）"
PUSHED=0
for NAME in "$BASE" "${BASE}-$(date +%m%d%H%M)" "${BASE}-$RANDOM"; do
  echo "  · 尝试仓库名：$NAME"
  # 先看看这个名字在远端是否已存在（存在的话直接复用，把代码推上去）
  if gh repo view "$USER/$NAME" >/dev/null 2>&1; then
    echo "    （已存在，复用它）"
    git remote remove origin 2>/dev/null
    git remote add origin "https://github.com/$USER/$NAME.git"
    if git push -u origin main 2>&1 | tail -5; then PUSHED=1; REPO=$NAME; break; fi
    echo "    git push 不通（网络问题），改用 API 推送…"
    if python3 "$(dirname "$0")/push-via-api.py" "$NAME" 2>&1 | tail -6; then
      PUSHED=1; REPO=$NAME; break
    fi
  else
    # 先只建仓库（--push 会走 git，网络不通时必失败，所以拆开）
    if OUT=$(gh repo create "$NAME" --public 2>&1); then
      echo "    ✓ 仓库已建"
      git remote remove origin 2>/dev/null
      git remote add origin "https://github.com/$USER/$NAME.git"
      if git push -u origin main 2>&1 | tail -3; then PUSHED=1; REPO=$NAME; break; fi
      echo "    git push 不通（网络问题），改用 API 推送…"
      if python3 "$(dirname "$0")/push-via-api.py" "$NAME" 2>&1 | tail -6; then
        PUSHED=1; REPO=$NAME; break
      fi
    else
      echo "    失败：$(echo "$OUT" | grep -iv '^$' | tail -2)"
    fi
  fi
done
[ "$PUSHED" = "1" ] || die "三个名字都没成。把上面 gh / python3 的真实报错发出来。"

say "5/6 触发云端编译"
gh workflow run build-apk.yml 2>/dev/null || echo "  （也可稍后在网页 Actions 页手动 Run workflow）"

say "6/6 完成"
printf '\033[32m✓ 仓库：https://github.com/%s/%s\033[0m\n' "$USER" "$REPO"
echo
echo "  编译进度：https://github.com/$USER/$REPO/actions"
echo "  等 5~8 分钟，变绿后：进那次运行 → 拉到底部 Artifacts → QQBotContainer-debug"
echo "  下载解压得到 app-debug.apk，点它安装。"
