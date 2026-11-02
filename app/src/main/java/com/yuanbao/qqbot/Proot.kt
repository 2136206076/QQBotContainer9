package com.yuanbao.qqbot

import android.content.Context
import android.system.Os
import java.io.File

/**
 * proot 封装。
 *
 * Android 10+ 有一条硬规则：App 不能 exec 自己数据目录里的文件（W^X / SELinux app_data_file），
 * 唯一保证可执行的目录是 APK 的 nativeLibraryDir。所以 proot 在构建期被改名为
 * libproot.so 塞进 jniLibs（和 libtalloc.so / libandroid-shmem.so / libproot-loader.so 一起），
 * 运行时从这里 exec。这也是 Termux、UserLAnd 的做法。
 */
object Proot {

    fun nativeDir(ctx: Context): File = File(ctx.applicationInfo.nativeLibraryDir)

    /** 动态库 staging 目录：proot 的 DT_NEEDED 写的是 libtalloc.so.2，这里给它造同名软链 */
    fun stageDir(ctx: Context): File = File(ctx.filesDir, "proot-lib").apply { mkdirs() }

    fun tmpDir(ctx: Context): File = File(ctx.filesDir, "tmp").apply { mkdirs() }

    fun shmDir(ctx: Context): File = File(ctx.filesDir, "shm").apply { mkdirs() }

    fun rootfs(ctx: Context): File = File(ctx.filesDir, Cfg.ROOTFS)

    fun prootBin(ctx: Context): File = File(nativeDir(ctx), "libproot.so")

    fun ready(ctx: Context): Boolean {
        val b = prootBin(ctx)
        return b.exists() && b.canExecute()
    }

    /** 第一次调用时造好软链（libtalloc.so.2 -> 真实 .so），之后幂等 */
    fun prepare(ctx: Context): String? {
        val nd = nativeDir(ctx)
        val bin = File(nd, "libproot.so")
        if (!bin.exists()) return "缺少 proot：构建前请跑 python3 tools/fetch-proot.py，或手动放 jniLibs/arm64-v8a/libproot.so"
        val st = stageDir(ctx)
        link(st, "libtalloc.so.2", File(nd, "libtalloc.so"))
        link(st, "libandroid-shmem.so", File(nd, "libandroid-shmem.so"))
        link(st, "libproot-loader.so", File(nd, "libproot-loader.so"))
        tmpDir(ctx); shmDir(ctx)
        try { Os.chmod(bin.absolutePath, 0b111_101_101) } catch (_: Exception) {}
        return null
    }

    private fun link(dir: File, name: String, target: File) {
        if (!target.exists()) return
        val l = File(dir, name)
        if (l.exists()) {
            val same = try { l.canonicalPath == target.canonicalPath } catch (_: Exception) { false }
            if (same) return
            l.delete()
        }
        try { Os.symlink(target.absolutePath, l.absolutePath) } catch (_: Exception) {
            try { target.copyTo(l, overwrite = true) } catch (_: Exception) {}
        }
    }

    /** 在容器里跑一段 bash。返回 Process，调用方负责读输出/等结束。 */
    fun shell(ctx: Context, script: String, extraEnv: Map<String, String> = emptyMap()): Process {
        val r = rootfs(ctx)
        val nd = nativeDir(ctx)
        val pb = ProcessBuilder()
        val cmd = mutableListOf(
            prootBin(ctx).absolutePath,
            "--link2symlink",
            "-0",
            "-r", r.absolutePath,
            "-b", "/dev", "-b", "/proc", "-b", "/sys",
            "-b", "/sdcard",
            "-b", "/storage",
            "-b", "${shmDir(ctx).absolutePath}:/dev/shm",
            "-w", "/root",
            "/usr/bin/env", "-i",
            "HOME=/root",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM=xterm",
            "LANG=C.UTF-8",
            "TZ=Asia/Shanghai",
            "DEBIAN_FRONTEND=noninteractive"
        )
        for ((k, v) in extraEnv) cmd.add("$k=$v")
        cmd.add("/bin/bash")
        cmd.add("-c")
        cmd.add(script)
        pb.command(cmd)
        pb.directory(File("/"))
        pb.redirectErrorStream(true)
        val env = pb.environment()
        env["LD_LIBRARY_PATH"] = "${stageDir(ctx).absolutePath}:${nd.absolutePath}"
        env["PROOT_LOADER"] = File(nd, "libproot-loader.so").absolutePath
        env["PROOT_TMP_DIR"] = tmpDir(ctx).absolutePath
        env["TMPDIR"] = tmpDir(ctx).absolutePath
        return pb.start()
    }

    /**
     * 收尾等待的上限（毫秒）。
     *
     * 子进程一退出，管道随即关闭，读线程会在几毫秒内收完尾 —— 这个上限纯粹是防御：
     * 万一子进程 fork 出去的后台进程还攥着管道写端（readLine() 就一直等不到 EOF），
     * 也不至于把调用方永久挂住。60s 对「收尾」绰绰有余，对 apt 那种 5~15 分钟的长命令
     * 完全不构成限制 —— 因为读线程是**全程并发**在消费的，不存在攒到最后一次性读的情况。
     */
    private const val READER_JOIN_TIMEOUT_MS = 60_000L

    /** 跑完一段脚本，把输出逐行喂给 LogBus，返回退出码 */
    fun run(ctx: Context, script: String, extraEnv: Map<String, String> = emptyMap(),
            tag: String = "sh"): Int {
        val p = shell(ctx, script, extraEnv)
        // 读线程必须**先于** waitFor() 起来：输出走的是管道，缓冲区只有几十 KB，
        // 写满了没人读，子进程就卡在 write() 上，waitFor() 也就永远等不到它结束。
        // 有这个线程在后台持续消费，子进程不会被管道堵住 —— 这是不死锁的前提。
        //
        // 不设 isDaemon = true：保持默认的非守护线程，这样即使调用方所在线程先结束，
        // JVM 也不会把正在往外倒日志的线程直接掐掉（日志丢一半比慢一点更难查）。
        val t = Thread {
            try {
                p.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { LogBus.log("[$tag] $it") }
                }
            } catch (_: Throwable) {}
        }
        t.start()
        // ⚠ 顺序不能颠倒：必须「先 waitFor() 再 join()」，原因：
        //   ① waitFor() 先返回 —— 读线程一直在消费管道，子进程不会因管道满而卡住，
        //      所以 waitFor() 一定能正常拿到退出码；
        //   ② 再 join() 等读线程收尾 —— 保证函数返回时，子进程输出的最后几行也已经
        //      喂进 LogBus。以前这里是 join(8000)：apt 那种长命令日志量大时，8 秒一到
        //      就提前返回，于是「== 完成 ==」先打出来、后面的日志才姗姗来迟，
        //      看起来像日志丢了。
        //   反过写（先 join 再 waitFor）会死锁：子进程还在跑、管道还在被写，
        //   读线程不退出 → join() 卡死 → waitFor() 根本没机会执行。
        //   用 finally 兜住：即使 waitFor() 被打断/抛异常，也一定去 join，不留悬挂线程。
        val code = try { p.waitFor() } finally { t.join(READER_JOIN_TIMEOUT_MS) }
        return code
    }

    /**
     * 常驻进程存活引用。
     *
     * Java 的 Process 对象即使被 GC，子进程本身也不会被杀（进程是 OS 资源），但
     * ProcessImpl 在 GC 时会关掉它的输入/输出流 —— 那样日志就读不到了。这里显式
     * 持住引用，同时顺手清掉已经死掉的，避免只增不减。
     */
    private val liveShells = java.util.Collections.synchronizedList(mutableListOf<Process>())

    /**
     * 启动一段会把服务留在后台的脚本，**不等待它结束**。
     *
     * 为什么需要这个方法：proot 是 ptrace supervisor，会一直等到它跟踪的**所有**
     * 子孙进程都退出才返回。start-all.sh 拉起的 Xvfb / x11vnc / websockify /
     * SnowLuma / QQ / 控制台全都是设计上就该常驻的进程，所以对这些进程用 [run]
     * 同步等待 = 永久阻塞。
     *
     * 真机上的表现（v1.3.2 实测）：一键部署走到 [10/10]，日志停在
     * 「下一步：bash /opt/qqstack/scripts/status.sh」，后面的「部署结果清单」
     * 和「部署结束」再也不会出现，界面一直转圈 —— 其实服务早就起来了。
     *
     * 这里改成「起完就走」：进程留着继续跑，输出照旧逐行进 LogBus（所以用户
     * 仍能看到 [start] 开头的日志继续往下滚）。要停服务走 stop-all.sh，
     * 那条路径会把所有子进程杀掉，proot 壳自然就退了。
     */
    fun launch(ctx: Context, script: String, tag: String = "bg",
               extraEnv: Map<String, String> = emptyMap()): Process {
        val p = shell(ctx, script, extraEnv)
        liveShells.add(p)
        // 清掉已经退出的壳（正常情况很少，主要是防止反复点「启动」时只增不减）
        try { liveShells.removeAll { !it.isAlive } } catch (_: Throwable) {}

        // 这种线程要 daemon：常驻进程活着的时候它就得一直读，但它不该阻止进程退出。
        val t = Thread(Runnable {
            try {
                p.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { LogBus.log("[$tag] $it") }
                }
            } catch (_: Throwable) {}
        }, "proot-$tag")
        t.isDaemon = true
        t.start()
        return p
    }

    /** 杀掉所有还在跑的 proot 壳（stop 时兜底用，防止叠了多个空壳）。 */
    fun killLiveShells() {
        try {
            liveShells.toList().forEach { if (it.isAlive) it.destroy() }
            liveShells.clear()
        } catch (_: Throwable) {}
    }
}
