# QQBotContainer —— 手机端 QQ 机器人专用容器 App

一个**只服务这一种用途**的安卓容器 App：打开 → 点「一键部署」→ 自己去拉 Ubuntu、装依赖、
编 hook、拉起 QQ + SnowLuma + QQ Agent，全程在 App 内完成，不用 Termux、不用 adb、不用敲命令。

> 前提：arm64 安卓手机（不支持 32 位）。Android 11+。建议 6GB 内存、留 4GB 空间。

---

## ⚠️ 安装与升级必读

**签名从 v1.1 起固定了。** 之前那些包是 GitHub Actions 每次自动生成的一次性 debug 证书，
每包都不一样，互相覆盖不了 —— 这正是以前「装了新版装不上、只能卸载」的原因。
现在仓库里带了固定签名库 `app/keystore/qfish-debug.jks`，之后所有构建签名一致，可以直接覆盖升级。

**⚠️ 但从旧版（v1.0 及更早）升到 v1.1，必须卸载重装一次。** 旧包的签名和新的对不上，
系统会拒绝覆盖。而容器（rootfs、QQ、登录态）都在 App 私有目录里，**卸载会一起删掉**，
重装后要重新跑一遍「一键部署」（约 20 分钟）和扫码登录。

> 之后就正常了：v1.1 起同签名的包可以随便覆盖安装，数据不会丢。

构建结束会自动校验产物指纹（Gradle task `verifyApkSignature`）：`assembleDebug` / `assembleRelease`
跑完即用 `apksigner` 读证书 SHA-256 与固定指纹比对，不一致直接让构建失败，避免又打出一个装不上的包。
签名库如果被误删也会在这里报错。想单独跑一次：`gradle verifyApkSignature`。

---

## 1. 它到底替你做了什么

```
点「一键部署」
  [1/9] 下载 Ubuntu Base 24.04 arm64（28MB）并解压        ← 自动，多源兜底
  [2/9] 写 resolv.conf / hosts（含屏蔽 QQ 热更新）/ apt 源
  [3/9] 把部署脚本放进容器 /opt/qqstack
  [4/9] apt 装包 + 换 Node 22 + 用 gcc 编出 hook 载入器     ← 最慢，5~15 分钟
  [5/9] 安装 QQ Agent（内置 2.7MB 离线包直接解压：免联网 / 免 npm install / 免编译）
  [6/9] 下载 SnowLuma 2.1.1 linux-arm64
  [7/9] 装 Linux 版 QQ（**这一步需要你给一个包**）
  [8/9] /proc/locks 补丁（能读就跳过）+ 路径别名 + 冻结热更新
  [9/9] 拉起：虚拟屏 → 协议端 → 带 hook 的 QQ → 控制台
```

跑完点「扫码登录」看二维码，「控制台」配模型和白名单。

---

## 2. 构建出 APK

> ⚠ **手机上别走电脑上那套**：Google 的 Android SDK 原生工具（aapt2 / zipalign）只有 x86_64 版本，
> 手机是 arm64，装了也会 `Exec format error`。下面按你的设备选路线。

### 路线 A：有电脑（最省事）

```bash
cd QQBotContainer
bash tools/make-apk.sh           # 自动装 JDK/SDK、拉 proot、出 APK
```
或者用 Android Studio 打开本目录，点 Run。

### 路线 B：只有手机（Termux）—— 推荐云端编译

```bash
pkg install git gh
bash tools/build-on-github.sh    # 推到 GitHub → 云端编译 → APK 下载到 /sdcard/Download
```
全程手机上操作，不用装 JDK/SDK。脚本会引导你用浏览器登录 GitHub，
然后自动建仓库、推送、等 Actions 跑完、把 APK 拉下来。公开仓库免费用 Actions。

### 路线 C：只有手机，且想本机编译

```bash
bash tools/build-termux.sh
```
它只装 SDK 里的纯 Java 部分，aapt2 换成 Termux 自带的 arm64 版本
（通过 `-Pandroid.aapt2FromMavenOverride=` 传参）。
第一次要下几百 MB 依赖，10~30 分钟，**别锁屏**。
如果卡在 `failed to load include path .../android.jar`，说明 Termux 的 aapt2 太旧 —— 换路线 B。

装到手机后**不要删通知**：App 用前台服务常驻，这是降低被系统回收概率的关键。

---

## 3. 部署前唯一要你动手的事：QQ 包

QQ 必须精确是 **3.2.32-52194 arm64**（SnowLuma 的 hook 是按这个版本编的，
版本不对就是"起来了但永远 awaiting readiness"）。官方 CDN 常对手机出口 IP 返 403，
App 没法替你下载，所以这一步留给你。

在 App 顶部的输入框里填**任意一个**：

| 形式 | 示例 |
|---|---|
| 本地文件路径 | `/sdcard/Download/QQ-3.2.32-52194-arm64.tar.gz`（推荐：把你之前 `tar -czf QQ-3.2.32-52194-arm64.tar.gz -C /opt QQ` 打的那个包传手机） |
| 本地 deb | `/sdcard/Download/QQ_3.2.32_260812_arm64_01.deb` |
| URL | 一个能直下的链接（GitHub 镜像、你自己搭的静态服务器都行） |

留空也能继续部署（其余组件照装），最后会在日志里提醒你补装，补完再点一次「一键部署」即可——
所有步骤都是幂等的，已装好的会跳过。

---

## 4. 保活（Android 12+ 必做）

容器 App 也绕不开「幽灵进程杀手」：Android 12 起限制每个 App 的子进程数，
QQ 一开（Chromium 十几个进程）就超，息屏一段时间后会被静默杀掉。
App 里的「保活指引」按钮会给出命令，一键复制，用**无线调试**或 **LADB / Shizuku** 执行一次即可：

```bash
adb shell device_config set_sync_disabled_for_tests persistent
adb shell device_config put activity_manager max_phantom_processes 2147483647
adb shell settings put global settings_enable_monitor_phantom_procs false
adb shell dumpsys deviceidle whitelist +com.yuanbao.qqbot
```

另外：系统设置 → 应用 → 本 App → 电池 → 选「不受限制」。

App 开机自启已内置（`BootReceiver`），前提是部署标记存在。

---

## 5. 日常使用

| 按钮 | 作用 |
|---|---|
| 启动 / 停止 | 拉起 / 全停（保留登录态） |
| 状态 | 各组件 + OneBot 连接 + 当前模型 |
| 版本体检 | 逐项对照实测可用版本，✗ 就是要处理 |
| hook 诊断 | hook 注入失败时抓现场（resident dispatch 那几行） |
| 控制台 | 内置 WebView 开 `127.0.0.1:3081`（QQ Agent 面板） |
| 扫码登录 | 内置 WebView 开 noVNC（`127.0.0.1:6081`，VNC 密码默认 `12345678`） |

---

## 6. 目录结构

```
app/src/main/
  java/com/yuanbao/qqbot/
    Proot.kt          proot 封装（nativeLibraryDir exec + staging 软链 + LD_LIBRARY_PATH）
    Installer.kt      部署编排：下载/解压/装包/打补丁/拉起
    DeployService.kt  前台服务，跑 9 步流程
    MainActivity.kt   一键部署 UI + 日志
    WebActivity.kt    内置控制台 / noVNC
    TarExtractor.kt   自研 tar 解压（硬链接降级为复制，绕开 Android 限制）
    BootReceiver.kt   开机自启
  assets/qqstack/     部署脚本 + patch + slhook.c（运行时拷进 /opt/qqstack）
  jniLibs/arm64-v8a/  proot 四件套（构建前由 python3 tools/fetch-proot.py 填）
tools/fetch-proot.py  从 Termux 仓库拆 proot deb
```

容器内布局：

```
/opt/QQ          Linux 版 QQ
/opt/snowluma    SnowLuma（5099 / 3000 / 3001）
/opt/qqagent     QQ Agent 0.4.0（原版纯 JS，入口 src/server.js；面板 3081，连 OneBot ws://127.0.0.1:3001）
/opt/qqstack/    libslhook.so、hook 载荷、scripts/、patch/、vncpasswd、run/*.pid
/opt/qqstack/agent/qqagent.pkg   内置的 QQ Agent 离线包（第 5 步从这里解压；名字不是 .tar.gz 是故意的，见第 8 节）
```

---

## 7. 已知限制（说实话）

1. **QQ 包必须你提供**，原因见第 3 节。
2. **resident dispatch 载荷（`libsnowluma_linux_resident_dispatch.so`）已由 App 自动导出**。
   proot 下 memfd 版 dlopen 加载不了，hook 的 dlopen 拦截器会退回磁盘路径加载，
   而这个磁盘文件发布包里从来不带 —— 之前我只能让你手动从原部署包 `bin/` 里拷。
   现在不需要了：它本来就**内嵌在 SnowLuma 主库**（`native/snowluma-linux-arm64.so`）里，
   App 会自动把它抠出来写到 `/opt/qqstack/libsnowluma_linux_resident_dispatch.so`
   （脚本：`tools/extract-resident-dispatch.py`，部署时随 assets 拷进容器 `/opt/qqstack/tools/`，
   偏移和长度都是运行时按 ELF header 算的，SnowLuma 升级也不会因为写死数字而失效）。
   三个入口都会跑：部署收尾、每次 `start-all.sh` 拉起 QQ 前、「hook 诊断」里还会自愈补一次。
3. **我没能替你在真机上跑一遍**：proot 参数、`--link2symlink`、
   `LD_LIBRARY_PATH` staging 这几处是按 Termux/UserLAnd 的通行做法写的，
   第一次部署如果卡住，点「hook 诊断」，把日志里 `[slhook]` 开头的行发出来定位。
4. rootfs 解压用的是自研 tar 解析器（约 1~2 分钟），比 C 版慢，胜在不依赖 toybox 版本。
5. 只做 arm64。

---

## 8. QQ Agent（大脑 / 控制台）

第 5 步从 App 内置的离线包 `assets/qqstack/agent/qqagent.pkg`（**2.7MB / 572 个文件**，其实是 gzip 过的 tar）
直接解压到 `/opt/qqagent`：**不 clone、不 `npm install`、不编译**——三个纯 JS 依赖
（`js-yaml` / `undici` / `ws`）已经打好在这个包的 `node_modules` 里，解压完
`node src/server.js` 就能起。这一步因此从「看网速」变成「看磁盘」：可重复、可离线，
包坏了重跑一次第 5 步就行。

> 为什么叫 `.pkg` 而不是 `.tar.gz`：AGP/aapt 打包时会把 assets 里**以 `.gz` 结尾**的文件
> 自动解压并丢掉 `.gz` 后缀（实测 APK 里变成了 8.4MB 的 `qqagent.tar`），容器里拿到的是
> 未压缩 tar，`tar -xzf` 直接报 `not in gzip format`。换成 `.pkg` 就能原样保留字节；
> 安装脚本仍会按文件头（`1f 8b`）判断要不要 `-z`，所以老的 `.tar.gz` / 裸 `.tar` 也认得。

它是**标准 OneBot v11 客户端**，默认连 `ws://127.0.0.1:3001` + `http://127.0.0.1:3000` ——
正好等于 `scripts/deploy.env` 里的 `BOT_WS` / `BOT_HTTP`，也就是本项目自己管的
SnowLuma v2.1.1，天然对接，不用改任何地址。

| 项 | 值 |
|---|---|
| 类型 | **原版纯 JavaScript**（ESM，包名 `qq-agent`，版本 **0.4.0**），入口 `src/server.js` |
| 安装方式 | 解压 App 内置离线包（**无需联网、无需 `npm install`、无需编译**） |
| 依赖 | `js-yaml` / `undici` / `ws` 已随包内置（`/opt/qqagent/node_modules/`） |
| Node | **≥ 20**（它 `package.json` 的 `engines` 就是 `>=20`；22.16.0 是旧 TypeScript 版的要求，内置版不需要，22.13.1 实测能正常起） |
| 面板 | `http://127.0.0.1:3081`（`/opt/qqagent/data/config.json` 的 `server.port`，只监听 127.0.0.1） |
| 配置 | `/opt/qqagent/data/config.json`（第 5 步生成；`loadConfig` = 内置默认值 + 这个文件深合并，所以只写要改的字段） |
| 日志 | `/tmp/qqagent.log` |

面板端口不用手改两份：第 5 步会读 `scripts/deploy.env` 的 `AGENT_PORT` / `BOT_WS` /
`BOT_HTTP` 写进 `config.json`。**改 `deploy.env` 之后重跑一次第 5 步**（或手改
`config.json` 里对应的值），两边对上即可 —— 对不上时症状是面板一直「未运行」，
而且每次启动都会重复拉起。

### 出厂默认关掉的「主动行为」

包里这 5 个插件默认是**开**的。装上就替用户给他的好友发消息、自动发说说显然不能是默认值，
所以第 5 步生成的配置把它们全关了：

| `config.json` → `skills` 键 | 默认 | 关掉的是什么 |
|---|---|---|
| `silence-ping` | `enabled: false` | 主动私信（原默认每 15~30 分钟给白名单里所有私聊对象发一条，每天最多 20 条） |
| `qzone-diary` | `enabled: false`、`autoGenerate: false` | 每 72 小时自动往 QQ 空间发说说 |
| `mood-qzone` | `signatureEnabled: false`、`qzoneEnabled: false` | 每天自动改个性签名、发说说 |
| `douyin-scroll` | `enabled: false` | 自己去刷抖音（点赞 / 评论 / 分享 / 回私信） |
| `self-surf` | `enabled: false` | 自己上网搜话题再发出来 |

要用哪个，就去面板左侧的「插件 / 技能」页逐个打开（改完即生效）——打开之后机器人会**真的**
用你的 QQ 号做这些事，包括给你的好友发私信，请自己确认清楚再开。

部署生成的默认配置就是下面这份（原文是单行，这里是格式化后的样子；可以拿去
`python3 -m json.tool` 验一下）：

```json
{
  "server": { "port": 3081 },
  "onebot": { "wsUrl": "ws://127.0.0.1:3001", "httpUrl": "http://127.0.0.1:3000" },
  "skills": {
    "silence-ping": { "enabled": false },
    "qzone-diary": { "enabled": false, "autoGenerate": false },
    "mood-qzone": { "signatureEnabled": false, "qzoneEnabled": false },
    "douyin-scroll": { "enabled": false },
    "self-surf": { "enabled": false }
  }
}
```

### 从旧版（TypeScript 版）升上来

第 5 步发现 `/opt/qqagent` 不是内置版时，会先整目录 `mv` 到 `/opt/qqagent.old-<时间戳>`
（日志里会打出**实际路径**），再解压新版。旧版的会话 / 记忆 / 人设都在它的 `data/` 里，
**新版目录结构不同、不能直接用**；要留档就在终端里 `cp -a /opt/qqagent.old-*/data /sdcard/`，
不需要就 `rm -rf` 掉省空间。

API Key 会自动迁移：依次找 旧 `data/config.json` 的 `api.{baseUrl,apiKey,model}` →
`.env`（解析 `KEY=VALUE`，含 `export` / 引号 / 注释）→ `config/app.yaml`（用 python3 的 yaml
解析），三个字段齐全才写入；三处都没找到会在日志里提示，去面板「模型接入」重填即可。

**必须自备 LLM API Key**：它是个"接入任意 AI API 的壳"，自己不提供模型。
支持 OpenAI 兼容 / Anthropic / Gemini / Ollama 等协议，在面板「模型接入」里填，
或写到 `/opt/qqagent/.env`（参考包里的 `.env.example`，变量名为 `providers.yaml` 里的 `apiKeyEnv`）。
**没配 Key 它只是个空壳** —— 面板能开、QQ 能连上，但不会回复。

**不要用它的内置 SnowLuma 安装器**：面板左侧 ❄ SnowLuma 页的「安装内置组件」
会把**上游固定版本 v1.14.22** 下载到 `runtime/snowluma/`，与本项目装的
**SnowLuma v2.1.1**（要和 QQ 3.2.32-52194 硬配对）冲突。本项目不使用该安装器 ——
协议端由 App 自己管理，Agent 只作为 OneBot 客户端连上来（也就是上游说的"方案 A"）。

状态里的 OneBot 连接情况取自 `/api/overview` 的 `runtime.napcatConnected` /
`runtime.onebot.connected`，账号是 `runtime.selfId` / `runtime.nickname`
（新版没有旧版的 `/api/status` 接口了）。

> ⚠ **许可提示**：内置包来自上游 **<https://github.com/Kondius/qq-agent>**（v0.4.0 原版），
> 包里带了它自己的 `LICENSE`（MIT，Copyright (c) 2026 Kondius）。二次分发时请一并保留。
> 之前的 TypeScript 分支（`shuang-ying/QQagent`）本项目已不再使用。

---

## 9. 许可

App 自身代码随意使用。注意 **proot 是 GPL-2.0、libtalloc 是 LGPL-3.0**，
你分发 APK 时需要同时提供这两个的源码（链接见 `app/src/main/jniLibs/README.md`）。
