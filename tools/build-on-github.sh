#!/data/data/com.termux/files/usr/bin/bash
# 路线 A（推荐）：把工程推到 GitHub，让云端编译，手机上直接下 APK。
# 手机上不用装 JDK / Android SDK / Gradle（那些原生工具在 arm64 上根本跑不了）。
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

say "1/4 装 git 和 gh（GitHub 命令行）"
pkg install -y git 2>/dev/null || apt-get install -y git 2>/dev/null || true
command -v git >/dev/null || die "装不上 git：pkg install git"
if ! command -v gh >/dev/null; then
  echo "  · 装 gh（GitHub 命令行）"
  pkg install -y gh 2>/dev/null || {
    echo "    Termux 源里没有 gh，直接下官方 arm64 二进制"
    V=v2.49.2
    curl -sL -o /tmp/gh.tgz "https://github.com/cli/cli/releases/download/${V}/gh_2.49.2_linux_arm64.tar.gz"
    tar xzf /tmp/gh.tgz -C /tmp
    cp /tmp/gh_2.49.2_linux_arm64/bin/gh "$PREFIX/bin/gh" 2>/dev/null || {
      mkdir -p "$HOME/bin"; cp /tmp/gh_2.49.2_linux_arm64/bin/gh "$HOME/bin/gh"
      export PATH="$HOME/bin:$PATH"; echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
    }
    chmod +x "$PREFIX/bin/gh" 2>/dev/null
  }
fi
command -v gh >/dev/null || die "gh 没装上。备用方案：手机浏览器打开 github.com 新建空仓库，本目录 git push 上去，再到仓库 Actions 页手动 Run workflow。"

say "2/4 登录 GitHub"
if ! gh auth status >/dev/null 2>&1; then
  echo "  接下来会让你选登录方式："
  echo "   · GitHub 账号登录（推荐）：选 GitHub.com → HTTPS → Login with a web browser，"
  echo "     它会给一个链接和一串验证码，用手机浏览器打开、填验证码、授权即可。"
  gh auth login --web --git-protocol https || die "登录失败"
fi
echo "  · 已登录：$(gh api user --jq .login 2>/dev/null || echo '?')"

say "3/4 建仓库并推送"
REPO=${REPO:-QQBotContainer}
if [ ! -d .git ]; then
  git init -q
  git add -A
  git -c user.email=bot@local -c user.name=qqbot commit -q -m "QQBotContainer: 手机端 QQ 机器人容器 App"
fi
git branch -M main 2>/dev/null || true
gh repo create "$REPO" --public --source . --remote origin --push 2>/dev/null \
  || gh repo create "$REPO" --private --source . --remote origin --push \
  || { git remote add origin "https://github.com/$(gh api user --jq .login)/$REPO.git" 2>/dev/null; git push -u origin main; }

say "4/4 等云端编译完成"
echo "  · 构建页面：$(gh repo view --json url -q .url)/actions"
RUN=$(gh run list --workflow "Build APK" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
if [ -z "$RUN" ]; then
  echo "  没自动触发，手动点一下："
  echo "    gh workflow run \"Build APK\""
  gh workflow run "Build APK" || true
  sleep 8
  RUN=$(gh run list --workflow "Build APK" --limit 1 --json databaseId -q '.[0].databaseId')
fi
echo "  · run id = $RUN，等待中（一般 3~8 分钟）…"
gh run watch "$RUN" || true

say "下载 APK"
mkdir -p /sdcard/Download 2>/dev/null
OUT=${OUT:-/sdcard/Download/QQBotContainer.apk}
if gh run download "$RUN" -n QQBotContainer-debug -D /tmp/qqbot-apk 2>/dev/null; then
  APK=$(find /tmp/qqbot-apk -name '*.apk' | head -1)
  cp "$APK" "$OUT" && printf '\n\033[32m✓ APK 已保存到 %s\033[0m\n' "$OUT"
else
  printf '\n\033[33m⚠ 自动下载失败，用手机浏览器打开下面的链接，\n  点最新的那次运行 → Artifacts → QQBotContainer-debug 下载：\n  %s/actions\033[0m\n' "$(gh repo view --json url -q .url)"
fi
echo
echo "装 APK：在文件管理器里点 $OUT ，允许「未知来源」即可。"
echo "（或用 gh 之外的方式：adb install -r $OUT）"
