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

    fun download(url: String, out: File, onProgress: (Long, Long) -> Unit) {
        out.parentFile?.mkdirs()
        var current: String = url
        var redirects = 0
        while (redirects < 8) {
            val conn = URL(current).openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = false
            conn.connectTimeout = 20_000
            conn.readTimeout = 60_000
            conn.setRequestProperty("User-Agent", "QQBotContainer/1.0")
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

    fun installScripts(ctx: Context) {
        try {
            val r = Proot.rootfs(ctx)
            val dest = File(r, "opt/qqstack")
            assetCopy(ctx, "qqstack", dest)
            val rc = Proot.run(ctx, "chmod -R +x /opt/qqstack/scripts /opt/qqstack/patch /opt/qqstack/tools /opt/qqstack/bin 2>/dev/null; " +
                    "mkdir -p /opt/qqstack/run /tmp/.X11-unix; echo ok", tag = "seed")
            LogBus.log(if (rc == 0) "✓ 部署脚本已就位 /opt/qqstack" else "✗ 脚本安装失败($rc)")
        } catch (e: Throwable) {
            CrashHandler.record("installScripts", e)
            LogBus.log("✗ 脚本安装异常：${e.message}")
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

    fun installAgent(ctx: Context): Boolean {
        val ok = Proot.run(ctx, """
            [ -f /opt/qqagent/src/server.js ] && { echo skip; exit 0; }
            mkdir -p /opt && cd /opt
            git clone --depth 1 ${Cfg.AGENT_GIT} qqagent 2>&1 | tail -8
            [ -f /opt/qqagent/src/server.js ] || { echo "clone 失败"; exit 1; }
            cd /opt/qqagent && npm install --omit=dev 2>&1 | tail -8
            echo "agent: ${'$'}(grep -m1 '"version"' package.json || echo '?')"
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
        LogBus.log("↓ 尝试自动下载 QQ 3.2.32 arm64（GitHub 归档源）…")
        val rc = Proot.run(ctx, """
            cd /tmp
            python3 /opt/qqstack/tools/fetch-qq.py --out /tmp/QQ.deb --build 52194 2>&1 | tail -20
            [ -s /tmp/QQ.deb ] || { echo "下载失败"; exit 1; }
            echo "下载完成: ${'$'}(du -h /tmp/QQ.deb | cut -f1)"
        """.trimIndent(), tag = "qqdl")
        return rc == 0
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

    private fun installFromSource(ctx: Context, src: String): Boolean {
        val pkg = if (src.startsWith("http")) "/tmp/qq.pkg" else src
        val dl  = if (src.startsWith("http"))
            "curl -fL --retry 3 -o '$pkg' '$src' || { echo '下载失败'; exit 1; }" else ""
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
            if cat /proc/locks >/dev/null 2>&1; then echo "locks: 可读，跳过补丁"; else
              python3 /opt/qqstack/patch/patch_snowluma.py /opt/snowluma/index.mjs 2>&1 | tail -5
              bash /opt/qqstack/scripts/mkfake-locks.sh
            fi
            bash /opt/qqstack/scripts/mkpath-alias.sh 2>&1 | tail -5
            bash /opt/qqstack/scripts/freeze-hotupdate.sh 2>&1 | tail -3
            touch ${Cfg.DEPLOYED_MARK}
        """.trimIndent(), tag = "patch")
    }

    fun start(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/start-all.sh 2>&1", tag = "start")
    fun status(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/status.sh 2>&1", tag = "status")
    fun stop(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/stop-all.sh 2>&1", tag = "stop")
    fun versions(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/versions.sh 2>&1", tag = "ver")
    fun diag(ctx: Context): Int = Proot.run(ctx, "bash /opt/qqstack/scripts/slhook-diag.sh 2>&1", tag = "diag")

    fun vncPassword(ctx: Context, pass: String): Int {
        val safe = pass.replace("'", "'\\''")
        return Proot.run(ctx, "x11vnc -storepasswd '$safe' /opt/qqstack/vncpasswd 2>&1 | tail -2", tag = "vnc")
    }
}
