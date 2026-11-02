package com.yuanbao.qqbot

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/** 部署流程编排：拉 rootfs → 装依赖 → 装三大件 → 打补丁 → 拉起。 */
object Installer {

    private fun assetCopy(ctx: Context, assetPath: String, dest: File) {
        val list = ctx.assets.list(assetPath)
        if (list.isNullOrEmpty()) {
            dest.parentFile?.mkdirs()
            ctx.assets.open(assetPath).use { i -> FileOutputStream(dest).use { o -> i.copyTo(o) } }
            return
        }
        dest.mkdirs()
        for (name in list) assetCopy(ctx, if (assetPath.isEmpty()) name else "$assetPath/$name", File(dest, name))
    }

    private fun isGzip(f: File): Boolean {
        if (!f.exists() || f.length() < 2) return false
        return f.inputStream().use { i ->
            i.read() == 0x1f && i.read() == 0x8b
        }
    }

    private fun isDeb(f: File): Boolean {
        if (!f.exists() || f.length() < 8) return false
        val magic = ByteArray(8)
        f.inputStream().use { it.read(magic) }
        return magic.contentEquals("!<arch>\n".toByteArray())
    }

    fun download(url: String, out: File, onProgress: (Long, Long) -> Unit) {
        out.parentFile?.mkdirs()
        var current: String = url
        var redirects = 0
        while (redirects < 8) {
            val conn = URL(current).openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = false
            conn.connectTimeout = 20_000
            conn.readTimeout = 60_000
            conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0.0.0")
            conn.connect()
            val code = conn.responseCode
            if (code in 300..399) {
                val loc = conn.getHeaderField("Location")
                conn.disconnect()
                if (loc.isNullOrEmpty()) throw IllegalStateException("重定向没有 Location: $code")
                current = if (loc.startsWith("http")) loc else URL(URL(current), loc).toString()
                redirects++
                continue
            }
            if (code !in 200..299) {
                conn.disconnect()
                throw IllegalStateException("HTTP $code $current")
            }
            val total = conn.contentLengthLong
            conn.inputStream.use { i ->
                FileOutputStream(out).use { o ->
                    val buf = ByteArray(1 shl 16)
                    var sum = 0L
                    while (true) {
                        val n = i.read(buf)
                        if (n <= 0) break
                        o.write(buf, 0, n)
                        sum += n
                        onProgress(sum, total)
                    }
                }
            }
            conn.disconnect()
            return
        }
        throw IllegalStateException("重定向次数过多: $url")
    }

    fun ensureRootfs(ctx: Context, url: String): Boolean {
        return try { ensureRootfsInner(ctx, url) }
        catch (e: Throwable) {
            CrashHandler.record("ensureRootfs($url)", e)
            LogBus.log("✗ rootfs 处理异常：${e.javaClass.simpleName}: ${e.message}")
            false
        }
    }

    private fun ensureRootfsInner(ctx: Context, url: String): Boolean {
        val r = Proot.rootfs(ctx)
        if (File(r, "bin/bash").exists()) {
            LogBus.log("· rootfs 已存在，跳过下载")
            return true
        }
        val gz = File(ctx.filesDir, "rootfs.tar.gz")
        if (!gz.exists() || gz.length() < 1_000_000) {
            LogBus.log("↓ 下载 Ubuntu Base（约 28MB）…")
            try {
                download(url, gz) { cur, total ->
                    if (total > 0) {
                        val pct = cur * 100 / total
                        if (pct % 10 == 0L) LogBus.log("↓ 下载 ${pct}%")
                    }
                }
            } catch (e: Throwable) {
                if (gz.exists()) gz.delete()
                throw e
            }
            if (gz.length() < 1_000_000 || !isGzip(gz)) {
                LogBus.log("✗ 下到的文件不像 gzip（${gz.length()} 字节），丢掉重试")
                gz.delete()
                return false
            }
        }
        LogBus.log("⇱ 解压 rootfs（约 1~2 分钟）…")
        r.mkdirs()
        val n = TarExtractor.extractGz(gz, r) { if (it % 2000 == 0L) LogBus.log("⇱ 已解出 $it 项") }
        LogBus.log("✓ rootfs 解压完成，共 $n 项")
        if (!File(r, "bin/bash").exists()) {
            LogBus.log("✗ 解压后没有 /bin/bash，包可能下坏了，下次会重下")
            if (gz.exists()) gz.delete()
            return false
        }
        gz.delete()
        for (d in listOf("proc", "sys", "dev", "dev/pts", "run", "tmp", "var/tmp", "sdcard")) File(r, d).mkdirs()
        return true
    }

    fun seed(ctx: Context) {
        val r = Proot.rootfs(ctx)
        File(r, "etc/resolv.conf").writeText("nameserver 223.5.5.5\nnameserver 8.8.8.8\n")
        File(r, "etc/hosts").writeText(
            "127.0.0.1 localhost\n::1 localhost\n0.0.0.0 qqpatch.gtimg.cn\n"
        )
        val p = File(r, "usr/sbin/policy-rc.d")
        p.parentFile?.mkdirs()
        p.writeText("#!/bin/sh\nexit 101\n")
        p.setExecutable(true, false)
        File(r, "etc/apt/sources.list").apply {
            parentFile?.mkdirs()
            writeText(
                "deb ${Cfg.APT_SOURCE} noble main restricted universe multiverse\n" +
                "deb ${Cfg.APT_SOURCE} noble-updates main restricted universe multiverse\n" +
                "deb ${Cfg.APT_SOURCE} noble-security main restricted universe multiverse\n"
            )
        }
        File(r, "etc/apt/apt.conf.d/99no-install-recommends").apply {
            parentFile?.mkdirs()
            writeText("APT::Install-Recommends \"false\";\nAPT::Install-Suggests \"false\";\nAcquire::Retries \"3\";\n")
        }
        LogBus.log("✓ 已写入 resolv.conf / hosts（含热更新屏蔽）/ apt 配置（ubuntu-ports）")
    }

    /** 容器内脚本目录（只做路径拼接，不 create —— 没部署过时 exists() 为 false 即可）。 */
    private fun stackScriptsDir(ctx: Context): File = File(Proot.rootfs(ctx), "opt/qqstack/scripts")

    /** 版本戳：内容 = 本 APK 的 lastUpdateTime，代表「容器里的脚本是哪一版 APK 带进来的」。 */
    private fun scriptsStampFile(ctx: Context): File = File(Proot.rootfs(ctx), "opt/qqstack/.scripts-stamp")

    /**
     * 本 APK 的安装/更新时间戳，用作脚本版本号。
     *
     * API 33 起 `getPackageInfo(String, int)` 被标 deprecated（不是删除），34 上仍能编译，
     * 但会刷 deprecation 警告；这里按 SDK_INT 分支走 PackageInfoFlags 新重载，
     * 老系统留 deprecated 分支并单独 @Suppress，两条路都只在后台线程调用（无 StrictMode 风险）。
     */
    private fun apkStamp(ctx: Context): String {
        val pm = ctx.packageManager
        val info = if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(ctx.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(ctx.packageName, 0)
        }
        return info.lastUpdateTime.toString()
    }

    /**
     * 把 assets/qqstack 复制进 /opt/qqstack 并补执行位。
     *
     * @param keepUserConfig 同步（APK 更新后刷脚本）时为 true：保留容器里已有的
     *   scripts/deploy.env —— VNC_PASS / 端口 / 目录这些用户可能手工改过，
     *   被 assets 里的默认值覆盖掉会直接把用户的配置清空。
     *   首次部署（默认 false）行为与改动前完全一致：无条件覆盖。
     * @return 是否成功（chmod 那一步退出码为 0）。
     */
    fun installScripts(ctx: Context, keepUserConfig: Boolean = false): Boolean {
        return try {
            val r = Proot.rootfs(ctx)
            val dest = File(r, "opt/qqstack")
            val envFile = File(dest, "scripts/deploy.env")
            // 同步（而非首次部署）时保留用户改过的 deploy.env：VNC_PASS / 端口都在里面
            val savedEnv = if (keepUserConfig && envFile.exists()) envFile.readBytes() else null
            assetCopy(ctx, "qqstack", dest)
            if (savedEnv != null) {
                envFile.parentFile?.mkdirs()
                envFile.writeBytes(savedEnv)
            }
            val rc = Proot.run(ctx, "chmod -R +x /opt/qqstack/scripts /opt/qqstack/patch /opt/qqstack/tools /opt/qqstack/bin 2>/dev/null; " +
                    "mkdir -p /opt/qqstack/run /tmp/.X11-unix; echo ok", tag = "seed")
            LogBus.log(if (rc == 0) "✓ 部署脚本已就位 /opt/qqstack" else "✗ 脚本安装失败($rc)")
            // 装成功才写戳：失败（比如 proot 忙）时不留痕，下次入口再试一遍，
            // 否则一次偶发失败会永久标记「已同步」，用户的旧脚本再也刷不上来。
            if (rc == 0) markScriptsSynced(ctx)
            rc == 0
        } catch (e: Throwable) {
            CrashHandler.record("installScripts", e)
            LogBus.log("✗ 脚本安装异常：${e.message}")
            false
        }
    }

    /** 写版本戳（失败忽略：戳写不上只是会多重同步一次，不影响功能）。 */
    private fun markScriptsSynced(ctx: Context) {
        try {
            scriptsStampFile(ctx).writeText(apkStamp(ctx))
        } catch (_: Throwable) {
        }
    }

    /**
     * APK 更新后把容器里的脚本刷成新版。
     *
     * 用 packageManager 的 lastUpdateTime 当版本戳：装了新 APK 才同步一次，平时点按钮零开销
     * （assetCopy + chmod 要起一次 proot，约 1~3 秒，不能每次都做）。
     * 失败只记日志不阻断 —— 脚本旧一点总比按钮点不动好。
     *
     * 未部署过（/opt/qqstack/scripts 不存在）直接返回，交给「一键部署」第 3 步。
     * 这里只读 exists()，不会在没部署的机器上凭空造出 /opt/qqstack 目录。
     *
     * @Synchronized：状态/拉起可能被连点（DeployService 每次 startService 起一个线程），
     * 两个线程同时 assetCopy 同一个目录会互相踩；串行化后最坏是第二个线程等 1~3 秒。
     */
    @Synchronized
    fun syncScriptsIfNeeded(ctx: Context) {
        try {
            if (!stackScriptsDir(ctx).exists()) return   // 还没部署过，交给部署流程
            val stamp = scriptsStampFile(ctx)
            val want = apkStamp(ctx)
            if (stamp.exists() && stamp.readText().trim() == want) return
            LogBus.log("· APK 已更新，同步容器内脚本…")
            if (installScripts(ctx, keepUserConfig = true)) {
                LogBus.log("✓ 脚本已同步到新版")   // installScripts 成功时已写戳
            } else {
                LogBus.log("· 脚本同步失败，不会影响后续操作，下次入口会再试")
            }
        } catch (e: Throwable) {
            LogBus.log("· 脚本同步跳过：${e.message}")
        }
    }

    fun bootstrap(ctx: Context): Boolean {
        val p = Proot.shell(ctx, "[ -f ${Cfg.BOOTSTRAP_MARK} ] && echo yes || echo no")
        val out = p.inputStream.bufferedReader().readText().trim()
        p.waitFor()
        if (out == "yes") { LogBus.log("· 系统包已装过，跳过（要重装：删 ${Cfg.BOOTSTRAP_MARK}）"); return true }
        LogBus.log("▶ apt 安装依赖 + Node 22 + 编译 hook（这一步最慢，5~15 分钟）")
        val rc = Proot.run(ctx, "bash /opt/qqstack/scripts/proot-bootstrap.sh 2>&1", tag = "boot")
        LogBus.log(if (rc == 0) "✓ 基础环境完成" else "✗ 基础环境失败($rc)，看上面 apt 报错")
        return rc == 0
    }

    /**
     * 装 QQ Agent（原版 qq-agent v0.4.0，纯 JavaScript + ESM，入口 src/server.js）。
     *
     * 为什么改成「内置包离线安装」：
     * 1. 旧流程走 clone + npm install + tsc 三步联网操作，proot 里连 registry.npmjs.org
     *    经常超时（要依次试镜像、还要编译），第 5 步因此成了整条部署链最不可靠的一环；
     *    而且那个 TypeScript 仓库本身也不稳定，随时可能再 404。
     * 2. 内置包 qqstack/agent/qqagent.tar.gz 已把 3 个纯 JS 依赖（js-yaml/undici/ws）
     *    打进 node_modules，所以**不用 clone、不用 npm install、不用编译**，解压完
     *    `node src/server.js` 就能起 —— 部署从「看网速」变成「看磁盘」，可重复、可离线。
     * 3. 就绪标志（三件套）：src/server.js + node_modules/ws + package.json。
     *    三者齐全才是可用的内置版；缺一个都按「旧版/残留」挪开重装，不会误判成已装而跳过。
     *
     * 下面几条是踩过的坑，改的时候别退回去：
     * - **解压失败必须清掉半装目录**（P0-1）：截断的包（磁盘满 / 写入被打断在收尾）能解出
     *   src/server.js + node_modules/ws + package.json —— 恰好凑齐三件套，下次复跑就
     *   「skip: 已是内置版」，于是永远装不起来。失败分支先 rm -rf 再 exit。
     * - **迁移临时文件（/tmp/qqagent-old-config.json 等）用后即删**（P0-2）：留着它，
     *   下一次「全新安装」（没有旧目录）会把上一轮的旧 API Key 无提示套进新配置。进来先删一遍，走完再删一遍。
     * - **出厂配置默认静默**（P0-3）：包里的 silence-ping / qzone-diary / mood-qzone /
     *   douyin-scroll / self-surf 默认全开，新用户一填 Key，机器人就会主动私聊他的好友、
     *   每 72 小时自动发说说 —— 那是替用户做社交动作，绝不能当默认值。
     * - **端口/地址读 deploy.env**（P0-4）：用户改过 AGENT_PORT 时若还写死 3081，
     *   面板起在 3081、脚本探 3001，症状是永远「未运行」且每次启动都重复拉起。
     * - **旧版备份要说清后果**（P1-5）：只打一句「挪开后重装」，用户既不知道数据去哪了，
     *   也不知道新版读不了旧 data/。
     * - **API Key 迁移要认旧版真实位置**（P1-6）：旧版是 TypeScript 项目，配置在
     *   config/app.yaml、Key 在 .env（变量名由 providers.yaml 的 apiKeyEnv 决定）；
     *   data/config.json 只有在面板里填过 Key 的容器才有 —— 只认它等于大概率静默失败。
     */
    fun installAgent(ctx: Context): Boolean {
        // 只重跑第 5 步时 /opt/qqstack/agent 可能还没被复制过去（那是第 3 步做的事），
        // 这里补一次：assetCopy 幂等，包只有 2.7MB，代价远小于「包缺失 → 部署失败」。
        try {
            val agentAssets = File(Proot.rootfs(ctx), "opt/qqstack/agent")
            if (!File(agentAssets, "qqagent.tar.gz").exists()) {
                assetCopy(ctx, "qqstack/agent", agentAssets)
            }
        } catch (e: Throwable) { CrashHandler.record("installAgent.seed", e) }

        val ok = Proot.run(ctx, """
            # ---- 端口 / 地址：以 deploy.env 为准（用户可能改过 AGENT_PORT / BOT_WS / BOT_HTTP）----
            # deploy.env 内部都是 ${'$'}{XXX:-默认值} 写法，重复 source 是幂等的。
            [ -f /opt/qqstack/scripts/deploy.env ] && . /opt/qqstack/scripts/deploy.env 2>/dev/null || true
            AG_PORT_TPL="${'$'}{AGENT_PORT:-3081}"
            BOT_WS_TPL="${'$'}{BOT_WS:-3001}"
            BOT_HTTP_TPL="${'$'}{BOT_HTTP:-3000}"

            # 这两个路径**写死**、不跟 deploy.env 走：Kotlin 侧 installScripts() 固定把
            # assets/qqstack 复制到 /opt/qqstack，两边不一致就会「找不到包」。
            AGENT_DIR=/opt/qqagent
            PKG=/opt/qqstack/agent/qqagent.tar.gz

            # 迁移用的三个临时文件（旧 data/config.json / .env / config/app.yaml 的副本）。
            # 进门先删一遍：上一轮万一没删干净，留着它会把上一轮的旧 API Key 无提示地套到
            # 这一次「全新安装」上 —— 用户根本没有旧目录，却凭空多出一个 Key。
            OLD_CFG=/tmp/qqagent-old-config.json
            OLD_ENV=/tmp/qqagent-old-env
            OLD_YAML=/tmp/qqagent-old-app.yaml
            rm -f "${'$'}OLD_CFG" "${'$'}OLD_ENV" "${'$'}OLD_YAML" 2>/dev/null || true

            # 跳过判定：内置版三件套（入口 server.js + 内置依赖 ws + package.json）都在才跳过。
            # 之所以带上 node_modules/ws：只解压了一半（比如磁盘满、被 kill）时 server.js 可能已在，
            # 但依赖不齐起不来 —— 那样跳过去就是留个坏装。
            if [ -f "${'$'}AGENT_DIR/src/server.js" ] && [ -d "${'$'}AGENT_DIR/node_modules/ws" ] && [ -f "${'$'}AGENT_DIR/package.json" ]; then
              echo "skip: 已是内置版 QQ Agent（原版 JS，免联网）"
              # 上一版 APK 装出来的 config.json 里没有 skills 段 —— 那 5 个主动插件还是默认开着的
              # （新用户一填 Key 就会被动私聊好友）。只在「整个 skills 段都不存在」时补一次默认值：
              # 用户只要动过任何一项（哪怕改回开启），skills 段就在，这里绝不再覆盖他的选择。
              if [ -f "${'$'}AGENT_DIR/data/config.json" ] && ! grep -q '"skills"' "${'$'}AGENT_DIR/data/config.json" 2>/dev/null; then
                python3 - "${'$'}AGENT_DIR/data/config.json" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
if not isinstance(data, dict) or 'skills' in data:
    sys.exit(0)
data['skills'] = {
    'silence-ping': {'enabled': False},
    'qzone-diary': {'enabled': False, 'autoGenerate': False},
    'mood-qzone': {'signatureEnabled': False, 'qzoneEnabled': False},
    'douyin-scroll': {'enabled': False},
    'self-surf': {'enabled': False}
}
try:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
except Exception:
    sys.exit(0)
print('· 老配置里没有 skills 段，已补上「主动行为默认关闭」（重启 QQ Agent 后生效；要在面板里按需开启）')
PY
              fi
              echo "agent: ${'$'}(node -p "require('/opt/qqagent/package.json').version" 2>/dev/null || echo '?')"
              exit 0
            fi

            if [ ! -f "${'$'}PKG" ]; then
              echo "✗ 内置包缺失：${'$'}PKG（请重跑「一键部署」第 3 步）"
              exit 1
            fi

            # 旧版/残留：先 mv 成 .old-<时间戳>（留个后悔药），mv 失败才 rm -rf，都失败才退出。
            if [ -e "${'$'}AGENT_DIR" ] || [ -L "${'$'}AGENT_DIR" ]; then
              echo "· ${'$'}AGENT_DIR 存在但不是内置版，挪开后重装"
              # 旧版的 API Key 可能藏在三个地方（顺序同下面的迁移段），mv 之前各捞一份到 /tmp。
              # 只拷不解析：解析统一交给下面那一个 python 脚本，省得 shell 里再写一遍引号转义。
              [ -f "${'$'}AGENT_DIR/data/config.json" ] && cp "${'$'}AGENT_DIR/data/config.json" "${'$'}OLD_CFG" 2>/dev/null || true
              [ -f "${'$'}AGENT_DIR/.env" ] && cp "${'$'}AGENT_DIR/.env" "${'$'}OLD_ENV" 2>/dev/null || true
              [ -f "${'$'}AGENT_DIR/config/app.yaml" ] && cp "${'$'}AGENT_DIR/config/app.yaml" "${'$'}OLD_YAML" 2>/dev/null || true
              OLD_DIR="/opt/qqagent.old-${'$'}(date +%s)"
              if mv "${'$'}AGENT_DIR" "${'$'}OLD_DIR" 2>/dev/null; then
                # 把「备份到哪」和「后果」都说清楚：旧数据不能直接用，别让用户以为升级后
                # 会话/记忆/人设还在（新版目录结构完全不同，读了也不会认）。
                echo "· 旧版（TypeScript 版）已整目录备份到：${'$'}OLD_DIR"
                echo "  旧版的会话/记忆/人设在 data/ 里，新版结构不同**不能直接用**；"
                echo "  需要留档就从「日志导出」旁边的终端进去拷走（cp -a ${'$'}OLD_DIR/data /sdcard/），不需要就 rm -rf 掉省空间。"
              elif rm -rf "${'$'}AGENT_DIR" 2>/dev/null; then
                echo "· 旧目录挪不动（/opt 空间可能不够），已直接删除，没有留备份"
              else
                echo "✗ ${'$'}AGENT_DIR 挪不走也删不掉，先手动删掉再重跑"
                rm -f "${'$'}OLD_CFG" "${'$'}OLD_ENV" "${'$'}OLD_YAML" 2>/dev/null || true
                exit 1
              fi
            fi

            mkdir -p "${'$'}AGENT_DIR" || exit 1
            echo "⇱ 解压内置包（2.7MB / 572 个文件，免联网）…"
            # 解压失败（包被截断 / 磁盘满 / 写入被打断）时**必须**先把半装目录清掉再退出：
            # 截断的包照样能解出 src/server.js + node_modules/ws + package.json 三件套，
            # 留着它下次复跑就直接「skip: 已是内置版」，用户永远装不起来。
            tar -xzf "${'$'}PKG" -C "${'$'}AGENT_DIR" || {
              echo "✗ 解压失败（包损坏或磁盘满），已清理半装目录，重跑即可"
              rm -rf "${'$'}AGENT_DIR" 2>/dev/null || true
              exit 1
            }
            [ -f "${'$'}AGENT_DIR/src/server.js" ] || {
              echo "✗ 解压后没有 src/server.js（包内容不对），已清理，重跑「一键部署」第 3 步"
              rm -rf "${'$'}AGENT_DIR" 2>/dev/null || true
              exit 1
            }

            # data/ 是刻意从包里剔出去的（里面有打包者的真实 API Key），这里现场造一个。
            # 只写要覆盖的字段：loadConfig 是 deepMerge(DEFAULT_CONFIG, 文件内容)，
            # 其余默认值自动补齐，所以不需要抄一份完整配置。
            #
            # skills 那一段是**出厂静默**：包里这 5 个插件默认是开的（silence-ping 会每
            # 15~30 分钟主动私聊用户的好友、最多 20 条/天，qzone-diary 每 72 小时自动发说说，
            # mood-qzone 每天改签名+发说说，douyin-scroll 自己去刷，self-surf 自己上网）。
            # 装完立刻替用户给他的好友发消息不能是默认行为 —— 要用的人去面板里自己开。
            mkdir -p "${'$'}AGENT_DIR/data"
            if [ ! -f "${'$'}AGENT_DIR/data/config.json" ]; then
              printf '{"server":{"port":%s},"onebot":{"wsUrl":"ws://127.0.0.1:%s","httpUrl":"http://127.0.0.1:%s"},"skills":{"silence-ping":{"enabled":false},"qzone-diary":{"enabled":false,"autoGenerate":false},"mood-qzone":{"signatureEnabled":false,"qzoneEnabled":false},"douyin-scroll":{"enabled":false},"self-surf":{"enabled":false}}}' "${'$'}AG_PORT_TPL" "${'$'}BOT_WS_TPL" "${'$'}BOT_HTTP_TPL" > "${'$'}AGENT_DIR/data/config.json"
              echo "· 已写默认配置：端口 ${'$'}AG_PORT_TPL，OneBot ws://127.0.0.1:${'$'}BOT_WS_TPL / http://127.0.0.1:${'$'}BOT_HTTP_TPL"
              echo "· 已默认关闭「主动私信 / 自动发说说 / 抖音滚动 / 自己上网」（避免替你的好友发消息），可在面板里按需开启"
            fi

            # ---- API Key 迁移（best-effort，绝不阻断部署）----
            # 旧版（shuang-ying/QQagent，TypeScript）根本不读 data/config.json：
            #   配置在 config/app.yaml（server.port / napcat.url），Key 在 .env
            #   （变量名由 providers.yaml 的 apiKeyEnv 指定）。data/config.json 只有在面板里
            #   填过 Key 的容器才有 —— 所以按三个来源依次探测，任一凑齐 baseUrl+apiKey+model
            #   就写入。只搬半截（有 model 没 key）反而会让面板显示「已配置」却调不通，比留空
            #   更难查，所以三字段必须齐全才写。
            # 为什么整段交给 python：config 是嵌套 JSON、.env 要处理 export/引号/注释、
            # app.yaml 得真解析 YAML —— sed 干不了这件事。
            if [ -f "${'$'}OLD_CFG" ] || [ -f "${'$'}OLD_ENV" ] || [ -f "${'$'}OLD_YAML" ]; then
              python3 - "${'$'}OLD_CFG" "${'$'}OLD_ENV" "${'$'}OLD_YAML" "${'$'}AGENT_DIR/data/config.json" <<'PY'
import json, os, sys

old_cfg, old_env, old_yaml, new_cfg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
DQ = chr(34)
SQ = chr(39)

def read_text(path):
    if not path or not os.path.isfile(path):
        return ''
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            return f.read()
    except Exception:
        return ''

def norm(url, key, model):
    out = {'baseUrl': str(url or '').strip(), 'apiKey': str(key or '').strip(), 'model': str(model or '').strip()}
    if out['baseUrl'] and out['apiKey'] and out['model']:
        return out
    return {}

def from_json(path):
    try:
        api = (json.loads(read_text(path)) or {}).get('api') or {}
    except Exception:
        return {}
    if not isinstance(api, dict):
        return {}
    return norm(api.get('baseUrl'), api.get('apiKey'), api.get('model'))

def parse_env(text):
    vals = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('export '):
            line = line[len('export '):].strip()
        if '=' not in line:
            continue
        name, value = line.split('=', 1)
        name = name.strip().upper()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in (DQ, SQ):
            value = value[1:-1]
        elif ' #' in value:
            value = value.split(' #', 1)[0].strip()
        if name and value:
            vals[name] = value
    return vals

def from_env(text):
    vals = parse_env(text)
    names = list(vals.keys())
    base, key, model = '', '', ''
    for name in names:
        if not base and ('BASE_URL' in name or 'API_BASE' in name):
            base = vals[name]
        if not model and (name == 'MODEL' or name.endswith('_MODEL')):
            model = vals[name]
    for name in names:
        if not key and ('API_KEY' in name or 'APIKEY' in name):
            key = vals[name]
    if not key:
        for name in names:
            if 'KEY' in name:
                key = vals[name]
                break
    return norm(base, key, model)

def from_yaml(path):
    text = read_text(path)
    if not text:
        return {}
    try:
        import yaml
    except Exception:
        print('· 容器里的 python3 没有 yaml 模块，跳过 config/app.yaml 这条来源')
        return {}
    try:
        data = yaml.safe_load(text) or {}
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    base, key, model = '', '', ''
    api = data.get('api')
    if isinstance(api, dict):
        base = api.get('baseUrl') or api.get('base_url') or ''
        key = api.get('apiKey') or api.get('api_key') or ''
        model = api.get('model') or ''
    providers = data.get('providers')
    if isinstance(providers, dict):
        for name in providers:
            one = providers.get(name)
            if not isinstance(one, dict):
                continue
            if not base:
                base = one.get('baseUrl') or one.get('base_url') or ''
            if not key:
                key = one.get('apiKey') or one.get('api_key') or ''
            if not model:
                model = one.get('model') or ''
    return norm(base, key, model)

def merge(source, picked):
    try:
        data = json.loads(read_text(new_cfg) or '{}')
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    api = data.get('api')
    if not isinstance(api, dict):
        api = {}
    api['baseUrl'] = picked['baseUrl']
    api['apiKey'] = picked['apiKey']
    api['model'] = picked['model']
    data['api'] = api
    try:
        with open(new_cfg, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print('· 旧配置迁移失败（新配置写不进去：%s），请在面板「模型接入」重新填 API Key' % e)
        return False
    print('✓ 已从旧版 %s 迁移 API Key（baseUrl / model 一并带过来）' % source)
    return True

sources = (
    ('data/config.json', lambda: from_json(old_cfg)),
    ('.env', lambda: from_env(read_text(old_env))),
    ('config/app.yaml', lambda: from_yaml(old_yaml))
)
for source, load in sources:
    picked = load()
    if picked and merge(source, picked):
        sys.exit(0)

print('· 没找到可迁移的旧配置（找过 data/config.json / .env / config/app.yaml），请在面板「模型接入」重新填 API Key')
PY
            fi
            # 无论迁移成功、失败，还是压根没走到（上面 if 不成立）都清掉：这三个文件就是
            # 「上一轮的旧 Key」，留着它等于给下一次全新安装埋雷。
            rm -f "${'$'}OLD_CFG" "${'$'}OLD_ENV" "${'$'}OLD_YAML" 2>/dev/null || true

            echo "agent: ${'$'}(node -p "require('/opt/qqagent/package.json').version" 2>/dev/null || echo '?')"
            echo "启动方式: node src/server.js（依赖已内置，免联网安装、免编译）"
        """.trimIndent(), tag = "agent")
        return ok == 0
    }

    fun installSnowLuma(ctx: Context): Boolean {
        val ok = Proot.run(ctx, """
            [ -f /opt/snowluma/index.mjs ] && { echo skip; exit 0; }
            cd /tmp
            curl -fL --retry 3 -o sl.tar.gz ${Cfg.SNOWLUMA_URL} || { echo "下载失败"; exit 1; }
            mkdir -p /opt/snowluma /tmp/sl-unpack
            tar xzf sl.tar.gz -C /tmp/sl-unpack
            if [ -f /tmp/sl-unpack/index.mjs ]; then
              cp -a /tmp/sl-unpack/. /opt/snowluma/
            else
              inner=${'$'}(find /tmp/sl-unpack -maxdepth 2 -name index.mjs | head -1)
              if [ -n "${'$'}inner" ]; then
                cp -a "${'$'}(dirname "${'$'}inner")"/. /opt/snowluma/
              else
                cp -a /tmp/sl-unpack/. /opt/snowluma/
              fi
            fi
            chmod +x /opt/snowluma/node /opt/snowluma/launcher.sh 2>/dev/null || true
            cat /opt/snowluma/release.json 2>/dev/null || true
            echo "node: ${'$'}(/opt/snowluma/node -v 2>/dev/null)"
            [ -f /opt/snowluma/index.mjs ] || { echo "解压后没有 index.mjs"; ls -la /opt/snowluma | head; exit 1; }
        """.trimIndent(), tag = "snowluma")
        return ok == 0
    }

    fun autoDownloadQQ(ctx: Context): Boolean {
        val dest = File(Proot.rootfs(ctx), "tmp/QQ.deb")
        dest.parentFile?.mkdirs()
        if (dest.isFile && dest.length() > 10_000_000 && isDeb(dest)) {
            LogBus.log("· 已有 /tmp/QQ.deb（${dest.length() / 1024 / 1024}MB），跳过下载")
            return true
        }
        LogBus.log("↓ 未填路径/链接，自动下载 QQ 3.2.32 arm64（约 200MB）")
        for (url in Cfg.QQ_URLS) {
            LogBus.log("↓ 尝试 $url")
            try {
                download(url, dest) { cur, total ->
                    if (total > 0) {
                        val pct = cur * 100 / total
                        if (pct % 10 == 0L) LogBus.log("↓ QQ ${pct}%")
                    }
                }
                if (dest.length() > 10_000_000 && isDeb(dest)) {
                    LogBus.log("✓ 下载完成 ${dest.length() / 1024 / 1024}MB")
                    return true
                }
                LogBus.log("· 下到的不像 deb（${dest.length()} 字节），换源")
            } catch (e: Throwable) {
                LogBus.log("· 失败：${e.javaClass.simpleName}: ${e.message}")
            }
            if (dest.exists()) dest.delete()
        }
        LogBus.log("✗ 内置源都下不到。可填本地 deb 路径或直链后重试")
        return false
    }

    fun installQQ(ctx: Context, source: String): Boolean {
        if (Proot.run(ctx, "[ -f /opt/QQ/resources/app/package.json ] && exit 0 || exit 9",
                tag = "qqchk") == 0) {
            Proot.run(ctx, "python3 -c \"import json;print('已有 QQ:', json.load(open('/opt/QQ/resources/app/package.json'))['version'])\" 2>/dev/null", tag = "qq")
            return true
        }
        val src = source.trim()
        if (src.isNotEmpty()) return installFromSource(ctx, src)
        if (autoDownloadQQ(ctx)) return installFromSource(ctx, "/tmp/QQ.deb")
        LogBus.log("✗ 自动下载没成功。手动方案：把 QQ_3.2.32_*_arm64_01.deb 放到手机，")
        LogBus.log("  在上方填 /sdcard/Download/QQ.deb 后重跑部署。")
        return false
    }

    private fun hostFileCandidates(src: String): List<File> {
        val s = src.trim()
        val name = File(s).name
        val alts = linkedSetOf(
            s,
            s.replace("/storage/emulated/0", "/sdcard"),
            s.replace("/sdcard", "/storage/emulated/0"),
            s.replace("/storage/emulated/0", "/storage/self/primary"),
            s.replace("/storage/self/primary", "/storage/emulated/0"),
            "/sdcard/Download/$name",
            "/storage/emulated/0/Download/$name",
            "/sdcard/Download/DLManager/$name",
            "/storage/emulated/0/Download/DLManager/$name"
        )
        return alts.filter { it.isNotEmpty() }.map { File(it) }
    }

    private fun findHostPkg(src: String): File? {
        for (f in hostFileCandidates(src)) {
            if (f.isFile && f.length() > 1024) return f
        }
        return null
    }

    private fun copyToGuestTmp(ctx: Context, host: File): String {
        val ext = when {
            host.name.endsWith(".tar.gz", true) || host.name.endsWith(".tgz", true) -> ".tar.gz"
            host.name.endsWith(".tar.xz", true) -> ".tar.xz"
            else -> ".deb"
        }
        val dest = File(Proot.rootfs(ctx), "tmp/QQ-install$ext")
        dest.parentFile?.mkdirs()
        LogBus.log("· 拷进容器：${host.absolutePath}（${host.length() / 1024 / 1024}MB）")
        host.inputStream().use { i ->
            FileOutputStream(dest).use { o ->
                val buf = ByteArray(1 shl 16)
                var sum = 0L
                val total = host.length()
                var lastPct = -1L
                while (true) {
                    val n = i.read(buf)
                    if (n <= 0) break
                    o.write(buf, 0, n)
                    sum += n
                    if (total > 0) {
                        val pct = sum * 100 / total
                        if (pct != lastPct && pct % 10 == 0L) {
                            lastPct = pct
                            LogBus.log("· 拷贝 ${pct}%")
                        }
                    }
                }
            }
        }
        if (dest.length() < 1024) throw IllegalStateException("拷贝后文件太小: ${dest.length()}")
        return "/tmp/QQ-install$ext"
    }

    private fun installFromSource(ctx: Context, src: String): Boolean {
        val pkg: String
        val dl: String
        if (src.startsWith("http")) {
            val ext = when {
                src.contains(".tar.gz") || src.contains(".tgz") -> ".tar.gz"
                src.contains(".tar.xz") -> ".tar.xz"
                else -> ".deb"
            }
            pkg = "/tmp/QQ-install$ext"
            val safe = src.replace("'", "'\\''")
            dl = "curl -fL --retry 3 -o '$pkg' '$safe' || { echo '下载失败'; exit 1; }"
        } else {
            val guestRel = src.trim().trimStart('/')
            val alreadyInGuest = File(Proot.rootfs(ctx), guestRel)
            if (alreadyInGuest.isFile && alreadyInGuest.length() > 1024) {
                pkg = if (src.startsWith("/")) src else "/$src"
                dl = ""
            } else {
                val host = findHostPkg(src)
                if (host == null) {
                    LogBus.log("✗ 宿主机找不到安装包。试过这些路径：")
                    hostFileCandidates(src).forEach {
                        LogBus.log("    ${it.absolutePath}  exists=${it.exists()} size=${if (it.exists()) it.length() else 0}")
                    }
                    LogBus.log("  去系统设置打开「所有文件访问」，路径可用 /sdcard/... 或 /storage/emulated/0/...")
                    return false
                }
                try {
                    pkg = copyToGuestTmp(ctx, host)
                } catch (e: Throwable) {
                    CrashHandler.record("copy QQ pkg", e)
                    LogBus.log("✗ 拷贝失败：${e.javaClass.simpleName}: ${e.message}")
                    LogBus.log("  去系统设置 → 应用 → 本 App → 打开「所有文件访问」后再试")
                    return false
                }
                dl = ""
            }
        }
        val script = """
            set -e
            cd /tmp
            $dl
            [ -f '$pkg' ] || { echo "文件不存在: $pkg"; exit 1; }
            mkdir -p /opt
            case '$pkg' in
              *.deb)           dpkg -i '$pkg' 2>&1 | tail -8 || true; apt-get install -y -f 2>&1 | tail -8 ;;
              *.tar.gz|*.tgz)  tar xzf '$pkg' -C /opt ;;
              *.tar.xz)        tar xJf '$pkg' -C /opt ;;
              *)               echo "不认识的包格式: $pkg"; exit 1 ;;
            esac
            rm -f '$pkg'
            chmod +x /opt/QQ/qq /opt/QQ/chrome-sandbox 2>/dev/null || true
            python3 -c "import json;print('QQ:', json.load(open('/opt/QQ/resources/app/package.json'))['version'])" 2>/dev/null || echo "QQ: 已安装但读不到版本"
            [ -f /opt/QQ/resources/app/package.json ] || { echo "安装后没有 /opt/QQ"; exit 1; }
        """.trimIndent()
        val rc = Proot.run(ctx, script, tag = "qq")
        if (rc != 0) LogBus.log("✗ QQ 安装失败($rc)。请确认包是 3.2.32 arm64 的 deb/tar.gz")
        return rc == 0
    }

    fun patchAndFinish(ctx: Context) {
        Proot.run(ctx, """
            # ---- /proc/locks 补丁：按退出码分辨走了哪条路 ----
            # patch_snowluma.py 的退出码约定：
            #   0 = 正常（方案 A 成功 / 已打过补丁跳过 / 按设计不用打补丁）
            #   3 = ⚠ 降级：方案 A 锚点缺失，实际写的是方案 B（替身文件兜底）
            #   其它 = 失败
            # 3 只是补丁精度下降，**不是部署失败** —— 这里只打醒目告警，绝不中断部署。
            # 脚本还会把实际走的路写进 ${'$'}{STACK_DIR:-/opt/qqstack}/.locks-patch-method。
            if cat /proc/locks >/dev/null 2>&1; then
              echo "locks: ✓ /proc/locks 可读，按设计不打补丁（不改动任何文件）"
              echo "       ↳ 如果 SnowLuma 仍报 EACCES /proc/locks，请加 --force 重跑："
              echo "         python3 /opt/qqstack/patch/patch_snowluma.py /opt/snowluma/index.mjs --force"
            else
              out=${'$'}(python3 /opt/qqstack/patch/patch_snowluma.py /opt/snowluma/index.mjs 2>&1); rc=${'$'}?
              echo "${'$'}out" | tail -6
              case "${'$'}rc" in
                0) echo "locks: ✓ 补丁完成（方案 A：结构化补丁，优选）" ;;
                3) echo "locks: ⚠⚠ 走了方案 B（替身文件兜底，退出码 3）—— 属降级成功，不中断部署" ;
                   echo "       ↳ 补丁是打上了，但精度不如方案 A，且替身文件有时效性（QQ 重启后 PID 会变）" ;
                   echo "       ↳ 建议核对 SnowLuma 版本（应与 QQ 3.2.32-52194 配对的 2.1.1）后重打方案 A" ;;
                *) echo "locks: ✗ 补丁失败（退出码 ${'$'}rc）—— 看上面的报错" ;
                   echo "       ↳ 不中断部署；但 SnowLuma 可能停在 awaiting readiness" ;;
              esac
              bash /opt/qqstack/scripts/mkfake-locks.sh
            fi
            bash /opt/qqstack/scripts/mkpath-alias.sh 2>&1 | tail -5
            bash /opt/qqstack/scripts/freeze-hotupdate.sh 2>&1 | tail -3
            # resident dispatch 载荷：proot 下 memfd 版 dlopen 加载不了，slhook.c 的拦截器会
            # 退回磁盘路径 ${'$'}RESIDENT_SO，而这个磁盘文件官方包不带 —— 只能从 SnowLuma 主库
            # 内嵌的 ELF 载荷里导出。脚本幂等、开销极小，所以每次都重跑：既能自愈掉地上残留的
            # 旧/坏 .so，也不会因为「文件碰巧存在」就误报成功。
            [ -f /opt/qqstack/scripts/deploy.env ] && . /opt/qqstack/scripts/deploy.env
            SRC_SO="${'$'}{HOOK_SO:-${'$'}{SNOWLUMA_DIR:-/opt/snowluma}/native/snowluma-linux-arm64.so}"
            DST_SO="${'$'}{RESIDENT_SO:-${'$'}{STACK_DIR:-/opt/qqstack}/libsnowluma_linux_resident_dispatch.so}"
            if [ -f "${'$'}SRC_SO" ] && [ -f /opt/qqstack/tools/extract-resident-dispatch.py ]; then
              out=${'$'}(python3 /opt/qqstack/tools/extract-resident-dispatch.py --source "${'$'}SRC_SO" --target "${'$'}DST_SO" 2>&1); rc=${'$'}?
              echo "${'$'}out" | tail -6
              if [ "${'$'}rc" -eq 2 ]; then
                echo "⚠ 载荷疑似不对（没匹配到 resident_dispatch 特征），已拒绝写出，${'$'}DST_SO 保持原样"
              elif [ "${'$'}rc" -eq 0 ] && python3 -c "import sys;d=open(sys.argv[1],'rb').read();sys.exit(0 if d[:4]==b'\x7fELF' and b'resident_dispatch' in d else 1)" "${'$'}DST_SO" 2>/dev/null; then
                echo "✓ resident dispatch 载荷已导出（ELF magic + resident_dispatch 特征都校验过）"
              else
                echo "⚠ 载荷导出失败：hook 会退回 stub，SnowLuma 可能停在 awaiting readiness"
              fi
            else
              echo "· SnowLuma 主库未就位，跳过 resident dispatch 导出"
            fi
            touch ${Cfg.DEPLOYED_MARK}
        """.trimIndent(), tag = "patch")
    }

    // 每个入口先同步一次脚本（装了新 APK 才真正干活，平时只是一个文件比对），
    // 再跑对应脚本 —— 保证用户装了新 APK 后不重装容器也能用上修好的脚本。
    // 调用方一律在后台线程（DeployService 的 thread{...}），同步里的文件 IO + proot 不会触发 StrictMode。
    fun start(ctx: Context): Int {
        syncScriptsIfNeeded(ctx)
        return Proot.run(ctx, "bash /opt/qqstack/scripts/start-all.sh 2>&1", tag = "start")
    }

    fun status(ctx: Context): Int {
        syncScriptsIfNeeded(ctx)
        return Proot.run(ctx, "bash /opt/qqstack/scripts/status.sh 2>&1", tag = "status")
    }

    fun stop(ctx: Context): Int {
        syncScriptsIfNeeded(ctx)
        return Proot.run(ctx, "bash /opt/qqstack/scripts/stop-all.sh 2>&1", tag = "stop")
    }

    fun versions(ctx: Context): Int {
        syncScriptsIfNeeded(ctx)
        return Proot.run(ctx, "bash /opt/qqstack/scripts/versions.sh 2>&1", tag = "ver")
    }

    fun diag(ctx: Context): Int {
        syncScriptsIfNeeded(ctx)
        return Proot.run(ctx, "bash /opt/qqstack/scripts/slhook-diag.sh 2>&1", tag = "diag")
    }

    fun vncPassword(ctx: Context, pass: String): Int {
        val safe = pass.replace("'", "'\\''")
        return Proot.run(ctx, "x11vnc -storepasswd '$safe' /opt/qqstack/vncpasswd 2>&1 | tail -2", tag = "vnc")
    }
}
