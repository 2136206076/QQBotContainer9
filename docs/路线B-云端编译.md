# 路线 B：手机上用 GitHub 云端编译出 APK

全程在手机 Termux 里操作，**不用装 JDK、Android SDK、Gradle**。
原理：把工程推到 GitHub，GitHub 的服务器（x86_64）帮你编译，编译完 APK 下载到手机。

耗时：首次约 10 分钟（登录 3 分钟 + 云端编译 5~8 分钟）。

---

## 0. 准备

| 需要 | 说明 |
|---|---|
| Termux | **从 F-Droid 装**（Play 版年久失修） |
| GitHub 账号 | 没有就用手机浏览器注册一个，免费的；**公开仓库编译完全免费** |
| 网络 | 能访问 github.com |
| 存储 | 工程很小（60KB），APK 约 5~15MB |

先把工程放到手机：

```bash
termux$ cd ~
termux$ mkdir -p qqbot && cd qqbot
# 把 QQBotContainer.zip 放到手机（QQ/微信发给自己、或浏览器下载），假设落在 ~/downloads
termux$ termux-setup-storage            # 授权访问 /sdcard（弹窗点允许）
termux$ cp /sdcard/Download/QQBotContainer.zip .
termux$ pkg install -y unzip git
termux$ unzip -q QQBotContainer.zip && cd QQBotContainer
termux$ ls                              # 应看到 app/ tools/ .github/ README.md
```

---

## 1. 一条命令（自动路线）

```bash
termux$ bash tools/build-on-github.sh
```

脚本会依次做：

1. 装 `git` + `gh`（Termux 源里没 gh 的话，自动下官方 arm64 二进制）
2. **登录 GitHub**：选 `GitHub.com` → `HTTPS` → `Login with a web browser`
   → 它会打印一个**链接 + 一串验证码**（形如 `ABCD-1234`）
   → **复制那个链接到手机浏览器打开**，填验证码，点授权
   → 回到 Termux，按回车继续
3. 自动建仓库（`QQBotContainer`）、`git push`
4. 等 Actions 跑完（脚本会实时刷进度，**一般 5~8 分钟**）
5. 把 APK 下载到 `/sdcard/Download/QQBotContainer.apk`

完成后去文件管理器点那个 APK 就能装（需允许「未知来源」）。

> 想改仓库名：`REPO=MyBot bash tools/build-on-github.sh`

---

## 2. 手动路线（脚本哪一步卡了就用这个）

### 2.1 登录
```bash
termux$ gh auth login
```
一路选：`GitHub.com` → `HTTPS` → `Login with a web browser` → 复制链接到浏览器 → 填验证码。

### 2.2 建仓库并推送
```bash
termux$ cd ~/qqbot/QQBotContainer
termux$ git init
termux$ git add -A
termux$ git -c user.email=me@x.com -c user.name=me commit -m "init"
termux$ gh repo create QQBotContainer --public --source . --remote origin --push
```

### 2.3 看云端编译
手机浏览器打开（把 `你的用户名` 换掉）：

```
https://github.com/你的用户名/QQBotContainer/actions
```

点最新那一条 → 等它变绿色 ✓（约 5~8 分钟）。
如果没自动触发，进仓库页面 → **Actions** → 左侧选 `Build APK` → 右边 `Run workflow`。

### 2.4 下 APK
- **方式一（推荐）**：Actions 那次运行页面往下拉，最底部 **Artifacts** 区 → 点 `QQBotContainer-debug` 下载 zip → 解压出 apk
- **方式二**：命令行
  ```bash
  termux$ gh run list --workflow "Build APK" --limit 1        # 看 run id
  termux$ gh run download <run-id> -n QQBotContainer-debug -D /sdcard/Download/
  ```

### 2.5 装
文件管理器点 APK → 允许「未知来源」→ 安装。
或者：`termux$ adb install -r /sdcard/Download/QQBotContainer.apk`（需无线调试）

---

## 3. 编译失败怎么办

进 Actions 页面点红色的那次运行，展开失败的 step 看日志。常见三种：

| 报错 | 原因 | 解法 |
|---|---|---|
| `fetch-proot` 失败 | 云端访问 packages.termux.dev 抽风 | 重跑一次（Actions 页右上角 `Re-run jobs`）；本地有 proot 四件套的话，手动放进 `app/src/main/jniLibs/arm64-v8a/` 再 push |
| gradle 相关 | wrapper 生成失败 | 看 2.4 节，一般重跑就好 |
| Kotlin/资源报错 | 我的代码问题 | 把报错发我 |

`fetchProot` 设了 `ignoreExitValue = true`，所以 proot 没下到**不会**让编译失败——
APK 照样能出，只是装上去 App 会提示「缺少 proot」。这种情况按
`app/src/main/jniLibs/README.md` 手动补四个 .so 再重新编译。

---

## 4. 出包之后

1. 装 APK，**别滑掉它的通知**（前台服务，用来降低被系统杀的概率）
2. 打开 App → 点「保活指引」，复制 adb 命令，用无线调试执行一次（Android 12+ 必做）
3. 回到 App，顶部填 QQ 包路径（或留空），点「一键部署」

QQ 包必须精确 **3.2.32-52194 arm64**，这一步我替不了你，详见工程 README 第 3 节。
