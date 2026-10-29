#!/data/data/com.termux/files/usr/bin/bash
# 路线 B：直接在手机 Termux 里编译（不下 Android SDK 的原生工具）。
#
# 为什么不能照搬电脑上的做法：Google 的 Android SDK 工具（aapt2 / zipalign）
# 只发布 x86_64 版本，手机上跑就是 Exec format error。
# 绕法：SDK 里只有 platform（android.jar，纯 Java）和 cmdline-tools（纯 Java）能用，
# 关键的 aapt2 换成 Termux 自带的 arm64 版本，通过 -Pandroid.aapt2FromMavenOverride= 传给 Gradle。
#
# 用法：bash tools/build-termux.sh
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

termux-wake-lock 2>/dev/null || true

say "1/6 装工具链（JDK 17 + aapt2 + gradle）"
pkg install -y openjdk-17 aapt2 gradle git unzip 2>/dev/null \
  || apt-get install -y openjdk-17-jdk aapt2 gradle git unzip 2>/dev/null \
  || echo "  ⚠ 部分包没装上，继续试"
export JAVA_HOME=/data/data/com.termux/files/usr/opt/openjdk
[ -d "$JAVA_HOME" ] || JAVA_HOME=$(dirname $(dirname $(readlink -f $(command -v java))))
if ! java -version 2>&1 | grep -qE '"1[7-9]|"2[0-9]'; then
  echo "  ⚠ 当前是 $(java -version 2>&1 | head -1)，AGP 8 需要 JDK 17"
  echo "    试试：pkg install openjdk-17，然后重跑本脚本"
fi
export PATH="$JAVA_HOME/bin:$PATH"
echo "  · JAVA_HOME=$JAVA_HOME"

AAPT2=/data/data/com.termux/files/usr/bin/aapt2
command -v aapt2 >/dev/null || die "缺 aapt2：pkg install aapt2"
echo "  · aapt2 = $AAPT2 ($(aapt2 version 2>&1 | head -1))"

say "2/6 准备 SDK（只要纯 Java 的那部分）"
SDK=${ANDROID_HOME:-$HOME/android-sdk}
mkdir -p "$SDK"
export ANDROID_HOME="$SDK"
echo "sdk.dir=$SDK" > local.properties
# cmdline-tools 是 Java 写的，arm64 能跑
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "  ↓ 装 cmdline-tools（约 130MB，纯 Java）"
  TMP=$(mktemp -d); curl -L -o "$TMP/c.zip" \
    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q "$TMP/c.zip" -d "$TMP"; rm -rf "$SDK/cmdline-tools"
  mkdir -p "$SDK/cmdline-tools"; mv "$TMP/cmdline-tools" "$SDK/cmdline-tools/latest"; rm -rf "$TMP"
fi
yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
"$SDK/cmdline-tools/latest/bin/sdkmanager" --install "platforms;android-34" >/dev/null 2>&1 \
  || echo "  ⚠ platform 安装失败；AGP 也可能会自己下载"
echo "  · SDK 就绪：$SDK"

say "3/6 准备 proot 二进制"
if [ -f app/src/main/jniLibs/arm64-v8a/libproot.so ]; then
  echo "  · 已有，跳过"
else
  python3 tools/fetch-proot.py || echo "  ⚠ 没下到，稍后手动放（app/src/main/jniLibs/README.md）"
fi

say "4/6 gradle wrapper"
if [ ! -f gradlew ]; then
  if command -v gradle >/dev/null; then
    gradle wrapper --gradle-version 8.2 --distribution-type bin 2>&1 | tail -2
  else
    die "没有 gradle 也生成不了 wrapper。改用路线 A：bash tools/build-on-github.sh"
  fi
fi
chmod +x gradlew

say "5/6 编译（第一次会下几百 MB 依赖，10~30 分钟，别锁屏）"
export GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx1536m -Dfile.encoding=UTF-8"
./gradlew assembleDebug \
  -Pandroid.aapt2FromMavenOverride="$AAPT2" \
  --no-daemon --stacktrace || {
    printf '\n\033[33m⚠ 编译失败。最常见的原因是 aapt2 版本太旧，\n' 
    printf '  解析不了 android-34 的 android.jar。两条路：\n'
    printf '   1) 换更新的 arm64 aapt2（ReVanced 有发布 aapt2-arm64-v8a），\n'
    printf '      放到 ~/aapt2 后把本脚本的 AAPT2 改掉再跑\n'
    printf '   2) 直接用云端编译：bash tools/build-on-github.sh\033[0m\n'
    exit 1
  }

say "6/6 完成"
APK=$(ls -t app/build/outputs/apk/debug/*.apk 2>/dev/null | head -1)
[ -n "$APK" ] || die "没找到产物"
cp "$APK" /sdcard/Download/QQBotContainer.apk 2>/dev/null && OUT=/sdcard/Download/QQBotContainer.apk || OUT="$APK"
printf '\n\033[32m✓ %s\033[0m\n' "$OUT"
echo "在文件管理器里点它就能装（需允许「未知来源」）。"
