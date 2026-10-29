package com.yuanbao.qqbot

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/** 部署流程编排：拉 rootfs → 装依赖 → 装三大件 → 打补丁 → 拉起。 */
object Installer {

    private fun assetCopy(ctx: Context, assetPath: String, dest: File) {
        val list = ctx.assets.list(assetPath)
        if (list.isNullOrEmpty()) {          // 是文件
            dest.parentFile?.mkdirs()
            ctx.assets.open(assetPath).use { i -> FileOutputStream(dest).use { o -> i.copyTo(o) } }
            return
        }
        dest.mkdirs()
        for (name in list) assetCopy(ctx, if (assetPath.isEmpty()) name else "$assetPath/$name", File(dest, name))
    }

    fun download(url: String, out: File, onProgress: (Long, Long) -> Unit) {
        out.parentFile?.mkdirs()
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.instanceFollowRedirects = true
        conn.connectTimeout = 20_000
        conn.readTimeout = 60_000
        conn.connect()
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
    }

    // ---------- 步骤 1：rootfs ----------
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
            download(url, gz) { cur, total ->
                if (total > 0) {
                    val pct = cur * 100 / total
                    if (pct % 10 == 0L) LogBus.log("↓ 下载 ${pct}%")
                }
            }
        }
        LogBus.log("⇱ 解压 rootfs（约 1~2 分钟）…")
        r.mkdirs()
        val n = TarExtractor.extractGz(gz, r) { if (it % 2000 == 0L) LogBus.log("⇱ 已解出 $it 项") }
        LogBus.log("✓ rootfs 解压完成，共 $n 项")
        gz.delete()
        // 挂载点目录
        for (d in listOf("proc", "sys", "dev", "dev/pts", "run", "tmp", "var/tmp", "sdcard")) File(r, d).mkdirs()
        return File(r, "bin/bash").exists()
    }

    // ---------- 步骤 2：rootfs 内部的基础文件 ----------
    fun seed(ctx: Context) {
        val r = Proot.rootfs(ctx)
        File(r, "etc/resolv.conf").writeText("nameserver 223.5.5.5\nnameserver 8.8.8.8\n")
        File(r, "etc/hosts").writeText(
            "127.0.0.1 localhost\n::1 localhost\n0.0.0.0 qqpatch.gtimg.cn\n"
        )
        // apt 装包时别去起服务（容器里没有 init）
        val p = File(r, "usr/sbin/policy-rc.d")
        p.parentFile?.mkdirs()
        p.writeText("#!/bin/sh\nexit 101\n")
        // ubuntu-base 自带的源常常缺 universe（novnc/websockify 就在 universe 里），直接重写
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
        LogBus.log("✓ 已写入 resolv.conf / hosts（含热更新屏蔽）/ apt 配置")
    }

    // ---------- 步骤 3：部署脚本进容器 ----------
    fun installScripts(ctx: Context) {
        try {
            val r = Proot.rootfs(ctx)
            val dest = File(r, "opt/qqstack")
            assetCopy(ctx, "qqstack", dest)
            val rc = Proot.run(ctx, "chmod -R +x /opt/qqstack/scripts /opt/qqstack/patch 2>/dev/null; " +
                    "mkdir -p /opt/qqstack/run /tmp/.X11-unix; echo ok", tag = "seed")
            LogBus.log(if (rc == 0) "✓ 部署脚本已就位 /opt/qqstack" else "✗ 脚本安装失败($rc)")
        } catch (e: Throwable) {
            CrashHandler.record("installScripts", e)
            LogBus.log("✗ 脚本安装异常：${e.message}")
        }
    }

    // ---------- 步骤 4：系统包 + Node + 编 hook ----------
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

    // ---------- 步骤 5：三大件 ----------
    fun installAgent(ctx: Context): Boolean {
        val ok = Proot.run(ctx, """
            [ -f /opt/qqagent/src/server.js ] && { echo skip; exit 0; }
            mkdir -p /opt && cd /opt
            git clone --depth 1 ${Cfg.AGENT_GIT} qqagent 2>&1 | tail -3
            cd /opt/qqagent && npm install --omit=dev 2>&1 | tail -5
            echo "agent: $(grep -m1 '"version"' package.json || echo '?')"
        """.trimIndent(), tag = "agent")
        return ok == 0
    }

    fun installSnowLuma(ctx: Context): Boolean {
        val ok = Proot.run(ctx, """
            [ -f /opt/snowluma/index.mjs ] && { echo skip; exit 0; }
            cd /tmp && curl -sL -o sl.tar.gz ${Cfg.SNOWLUMA_URL}
            mkdir -p /opt/snowluma && tar xzf sl.tar.gz -C /opt/snowluma
            chmod +x /opt/snowluma/node /opt/snowluma/launcher.sh 2>/dev/null
            cat /opt/snowluma/release.json 2>/dev/null
            echo "node: $(/opt/snowluma/node -v 2>/dev/null)"
        """.trimIndent(), tag = "snowluma")
        return ok == 0
    }

    /** 自动下载 QQ：GitHub 上有归档仓库把官方包同步到了 Releases，不走 QQ 的 CDN */
    fun autoDownloadQQ(ctx: Context): Boolean {
        LogBus.log("↓ 尝试自动下载 QQ 3.2.32 arm64（GitHub 归档源）…")
        val rc = Proot.run(ctx, """
            cd /tmp
            python3 /opt/qqstack/tools/fetch-qq.py --out /tmp/QQ.deb 2>&1 | tail -20
            [ -s /tmp/QQ.deb ] || { echo "下载失败"; exit 1; }
            echo "下载完成: $(du -h /tmp/QQ.deb | cut -f1)"
        """.trimIndent(), tag = "qqdl")
        return rc == 0
    }

    /** QQ 必须是指定的 3.2.32-52194。source 可以是 URL 或 /sdcard/... 的本地路径；留空则自动下载 */
    fun installQQ(ctx: Context, source: String): Boolean {
        if (Proot.run(ctx, "[ -f /opt/QQ/resources/app/package.json ] && exit 0 || exit 9",
                tag = "qqchk") == 0) {
            Proot.run(ctx, """echo "已有 QQ: $(python3 -c "import json;print(json.load(open('/opt/QQ/resources/app/package.json'))['version'])" 2>/dev/null)"""", tag = "qq")
            return true
        }
        val src = source.trim()
        if (src.isNotEmpty()) return installFromSource(ctx, src)
        if (autoDownloadQQ(ctx)) return installFromSource(ctx, "/tmp/QQ.deb")
        LogBus.log("✗ 自动下载没成功。手动方案：把 QQ_3.2.32_*_arm64_01.deb 放到手机，")
        LogBus.log("  在上方填 /sdcard/Download/QQ.deb 后重跑部署。")
        return false
    }

    private fun installFromSource(ctx: Context, src: String): Boolean {
        val script = """
            SRC="$src"
            [ -z "$SRC" ] && { echo "NO_SOURCE"; exit 2; }
            cd /tmp
            case "$SRC" in
              http*) curl -sL -o qq.pkg "$SRC" || { echo "下载失败"; exit 1; }; PKG=/tmp/qq.pkg ;;
              *)     PKG=$SRC ;;
            esac
            [ -f "${'$'}PKG" ] || { echo "文件不存在: ${'$'}PKG"; exit 1; }
            mkdir -p /opt
            case "${'$'}PKG" in
              *.deb)      dpkg -i "${'$'}PKG" 2>&1 | tail -3 || apt-get install -y -f 2>&1 | tail -3 ;;
              *.tar.gz|*.tgz) tar xzf "${'$'}PKG" -C /opt ;;
              *.tar.xz)   tar xJf "${'$'}PKG" -C /opt ;;
              *)          echo "不认识的包格式: ${'$'}PKG"; exit 1 ;;
            esac
            chmod +x /opt/QQ/qq /opt/QQ/chrome-sandbox 2>/dev/null
            echo "QQ: $(python3 -c "import json;print(json.load(open('/opt/QQ/resources/app/package.json'))['version'])" 2>/dev/null)"
        """.trimIndent()
        val rc = Proot.run(ctx, script, tag = "qq")
        if (rc == 2) LogBus.log("✗ 没给 QQ 包：请填 URL 或 /sdcard/Download/xxx.deb 的路径")
        return rc == 0
    }

    fun patchAndFinish(ctx: Context) {
        Proot.run(ctx, """
            # /proc/locks 能读就不打补丁，读不了才打
            if cat /proc/locks >/dev/null 2>&1; then echo "locks: 可读，跳过补丁"; else
              python3 /opt/qqstack/patch/patch_snowluma.py /opt/snowluma/index.mjs 2>&1 | tail -5
              bash /opt/qqstack/scripts/mkfake-locks.sh
            fi
            # 建路径别名（宿主路径 -> 容器路径），proot 下 hook 靠它找文件
            bash /opt/qqstack/scripts/mkpath-alias.sh 2>&1 | tail -5
            # 冻热更新
            bash /opt/qqstack/scripts/freeze-hotupdate.sh 2>&1 | tail -3
            touch ${Cfg.DEPLOYED_MARK}
        """.trimIndent(), tag = "patch")
    }

    // ---------- 运行 ----------
    fun start(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/start-all.sh 2>&1", tag = "start")
    fun status(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/status.sh 2>&1", tag = "status")
    fun stop(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/stop-all.sh 2>&1", tag = "stop")
    fun versions(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/versions.sh 2>&1", tag = "ver")
    fun diag(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/slhook-diag.sh 2>&1", tag = "diag")

    fun vncPassword(ctx: Context, pass: String): Int =
        Proot.run(ctx, "x11vnc -storepasswd '$pass' /opt/qqstack/vncpasswd 2>&1 | tail -2", tag = "vnc")
}
