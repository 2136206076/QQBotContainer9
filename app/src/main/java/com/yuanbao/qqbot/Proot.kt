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
        if (!bin.exists()) return "缺少 proot：构建前请跑 bash tools/fetch-proot.sh，或手动放 jniLibs/arm64-v8a/libproot.so"
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
        if (l.exists()) return
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
            "--link2symlink",          // Android 上硬链接不可靠，交给 proot 转成符号链接
            "-0",                      // 容器内当 root
            "-r", r.absolutePath,
            "-b", "/dev", "-b", "/proc", "-b", "/sys",
            "-b", "/sdcard",
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

    /** 跑完一段脚本，把输出逐行喂给 LogBus，返回退出码 */
    fun run(ctx: Context, script: String, extraEnv: Map<String, String> = emptyMap(),
            tag: String = "sh"): Int {
        val p = shell(ctx, script, extraEnv)
        val t = Thread {
            p.inputStream.bufferedReader().useLines { lines ->
                lines.forEach { LogBus.log("[$tag] $it") }
            }
        }
        t.start()
        val code = p.waitFor()
        t.join(5000)
        return code
    }
}
