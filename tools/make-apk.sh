#!/usr/bin/env bash
# 在电脑上一条命令出 APK（Linux / macOS / WSL）。
# Windows 请用 Git Bash 或直接看 README 的 Android Studio 步骤。
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

# Termux / 手机：Google 的 SDK 原生工具（aapt2 等）只有 x86_64，装了也跑不了。
# 直接转给手机专用脚本，别浪费 400MB 流量。
if [ -n "${PREFIX:-}" ] && [ -d /data/data/com.termux ]; then
  echo "检测到 Termux（手机）环境。"
  echo
  echo "  推荐：bash tools/build-on-github.sh   云端编译，手机上直接下 APK，不用装 SDK"
  echo "  本机：bash tools/build-termux.sh      在手机里编译（需 JDK17 + aapt2，10~30 分钟）"
  echo
  read -r -p "选哪个？[1=云端(推荐) 2=本机] " c
  case "$c" in
    2) exec bash "$(dirname "$0")/build-termux.sh" ;;
    *) exec bash "$(dirname "$0")/build-on-github.sh" ;;
  esac
fi

say "1/5 检查 JDK（AGP 8 需要 Java 17）"
if command -v java >/dev/null; then
  V=$(java -version 2>&1 | head -1)
  echo "  · $V"
  if java -version 2>&1 | grep -q '"1[18]\.\|"1\.'; then
    echo "  ⚠ 版本偏低，建议装 JDK 17：sudo apt install openjdk-17-jdk"
  fi
else
  die "没装 java：sudo apt install openjdk-17-jdk （macOS: brew install openjdk@17）"
fi

say "2/5 检查 Android SDK"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [ ! -d "$SDK" ]; then
  echo "  没找到 SDK，准备装一份到 $SDK（约 400MB，只下一次）"
  mkdir -p "$SDK/cmdline-tools"
  TMP=$(mktemp -d)
  curl -L -o "$TMP/cmd.zip" \
    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q "$TMP/cmd.zip" -d "$TMP"
  mv "$TMP/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -rf "$TMP"
fi
echo "  · SDK 在 $SDK"
echo "sdk.dir=$SDK" > local.properties

export ANDROID_HOME="$SDK"
CM=$SDK/cmdline-tools/latest/bin/sdkmanager
if [ -x "$CM" ]; then
  yes | "$CM" --licenses >/dev/null 2>&1 || true
  "$CM" --install "platform-tools" "platforms;android-34" "build-tools;34.0.0" >/dev/null 2>&1 \
    || echo "  ⚠ sdkmanager 装包失败，先用已有版本试试"
fi

say "3/5 准备 proot 二进制（会联 packages.termux.dev）"
if [ -f app/src/main/jniLibs/arm64-v8a/libproot.so ]; then
  echo "  · 已有，跳过（要重下：python3 tools/fetch-proot.py --force）"
else
  python3 tools/fetch-proot.py || echo "  ⚠ 没下下来，稍后手动放（见 app/src/main/jniLibs/README.md）"
fi

say "4/5 准备 gradle wrapper"
if [ ! -f gradlew ]; then
  if command -v gradle >/dev/null; then
    gradle wrapper --gradle-version 8.2 --distribution-type bin
  else
    echo "  ⚠ 系统没装 gradle，也没有 gradlew。"
    echo "    最省事的办法：用 Android Studio 打开本目录，它会自动生成 wrapper，"
    echo "    然后回到这里重新执行本脚本（或直接点 Studio 里的 Run）。"
    echo "    想纯命令行：sudo apt install gradle 后再跑一次。"
  fi
fi

say "5/5 编译"
if [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew assembleDebug || die "编译失败，看上面报错"
else
  die "没有 gradlew，也没法自动生成。请用 Android Studio 打开本目录。"
fi

APK=$(ls -t app/build/outputs/apk/debug/*.apk 2>/dev/null | head -1)
[ -n "$APK" ] || die "没找到产物 apk"
printf '\n\033[32m✓ 完成：%s\033[0m\n' "$(pwd)/$APK"
echo
echo "传到手机："
echo "  adb install -r $APK"
echo "  或 直接把文件发给手机，点开安装（需允许「未知来源」）"
echo
echo "提醒：这个 APK 用 debug 签名，装完别杀它的通知（前台服务，用来降低被回收概率）。"
