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

    /**
     * 装 QQ Agent（TypeScript 版，源见 Cfg.AGENT_GIT）。
     *
     * 三个和旧版不一样的关键点：
     * 1. 就绪标志是 package.json + src/index.ts，不是老的 src/server.js —— 残留的旧目录
     *    （或 clone 一半的目录）不能被误判成"已安装"。
     * 2. 依赖必须全量 npm install：tsx 和 typescript 都在 devDependencies，
     *    用 --omit=dev 装出来的树根本起不来（这是旧流程必失败的根因）。
     * 3. 装完 best-effort 编一次 dist（tsc → dist/src/index.js）：运行时用 node 跑编译产物
     *    比 tsx 现编现跑省内存、启动快，手机环境差别明显。但 tsconfig 开了 noUnusedLocals，
     *    scripts/ 下测试脚本一有未用变量 tsc 就编不过，所以编译只做 best-effort
     *    —— 编不过不阻断部署，start-all.sh 会自动退回 tsx src/index.ts。
     */
    fun installAgent(ctx: Context): Boolean {
        val ok = Proot.run(ctx, """
            if [ -f /opt/qqagent/package.json ] && [ -f /opt/qqagent/src/index.ts ]; then
              echo "skip: /opt/qqagent 已是 TypeScript 版 QQ Agent"
              exit 0
            fi
            mkdir -p /opt && cd /opt
            # 用 -e/-L 而不是 -d：/opt/qqagent 可能是个坏掉的软链接（自己链自己那种），
            # 那种情况下 -d 为假、git clone 又会报 "File exists"，正好卡死在这一步
            if [ -e /opt/qqagent ] || [ -L /opt/qqagent ]; then
              echo "· /opt/qqagent 存在但不是新仓库（缺 src/index.ts），挪开后重新 clone"
              # 先 mv（保留里面可能已有的 config/ —— API Key 之类的配置不跟着一起没），
              # mv 不动（坏软链接、跨设备等）再 rm -rf
              mv /opt/qqagent "/opt/qqagent.old-${'$'}(date +%s)" 2>/dev/null \
                || rm -rf /opt/qqagent 2>/dev/null \
                || { echo "✗ /opt/qqagent 挪不走，先手动删掉再重跑"; exit 1; }
            fi
            echo "↓ git clone ${Cfg.AGENT_GIT}（约 2~3MB）"
            git clone --depth 1 ${Cfg.AGENT_GIT} qqagent 2>&1 | tail -8
            [ -f /opt/qqagent/src/index.ts ] || { echo "clone 失败（仓库不可达？）"; exit 1; }
            cd /opt/qqagent || exit 1
            # API Key 模板：面板「模型接入」也能填，这里只是给用户一个落点（全注释，不影响运行）
            [ -f .env ] || cp .env.example .env 2>/dev/null || true
            echo "node: ${'$'}(node -v 2>/dev/null || echo '未安装')（QQ Agent 要 ≥22.16.0：低版本内置 SQLite 没有 FTS5，会报 no such module: fts5）"
            echo "· npm install（必须全量：tsx/typescript 是 devDependencies；sharp 走 arm64 预编译包，可能要几分钟）…"
            npm install --no-audit --no-fund 2>&1 | tail -12
            [ -x node_modules/.bin/tsx ] || { echo "✗ 依赖不完整：没装到 tsx（看上面 npm 报错）"; exit 1; }
            echo "· npm run build（tsc → dist/src/index.js；编不过也没关系，会退回 tsx）…"
            npm run build 2>&1 | tail -5
            build_rc=${'$'}{PIPESTATUS[0]}
            if [ "${'$'}build_rc" -eq 0 ] && [ -f dist/src/index.js ]; then
              echo "✓ 已编译 dist/src/index.js（启动走 node，省内存、启动快）"
            else
              echo "⚠ tsc 编译未通过（退出码 ${'$'}build_rc）—— 不阻断部署，运行时改用 tsx src/index.ts"
            fi
            echo "agent: ${'$'}(node -p "require('./package.json').version" 2>/dev/null || echo '?')"
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
