package com.yuanbao.qqbot

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 崩溃捕获：闪退时把完整堆栈写到文件，不用连电脑抓 logcat。
 * 落盘位置（按可写性依次尝试）：/sdcard/Download/qqbot-crash.txt → filesDir/crash.txt
 *
 * 自包含：ctx 由 Application / MainActivity / DeployService 设置。
 */
object CrashHandler {

    @Volatile
    var ctxRef: Context? = null

    private fun dir(): File {
        val c = ctxRef
        if (c != null) return c.filesDir
        return File("/data/local/tmp")
    }

    fun file(): File = File(dir(), "crash.txt")

    @Synchronized
    fun install(c: Context) {
        ctxRef = c.applicationContext
        val cur = Thread.getDefaultUncaughtExceptionHandler()
        if (cur === handler) return
        prev = cur
        Thread.setDefaultUncaughtExceptionHandler(handler)
    }

    @Volatile
    private var prev: Thread.UncaughtExceptionHandler? = null

    private val handler = Thread.UncaughtExceptionHandler { t, e ->
        try { save(t, e) } catch (_: Throwable) {}
        prev?.uncaughtException(t, e)
    }

    private fun save(t: Thread, e: Throwable) {
        val f = file()
        f.parentFile?.mkdirs()
        val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date())
        val sb = StringBuilder()
        sb.appendLine("========== 崩溃 $ts ==========")
        sb.appendLine("线程: ${t.name}")
        sb.appendLine("异常: ${e.javaClass.name}: ${e.message}")
        sb.appendLine()
        sb.appendLine("--- 堆栈 ---")
        e.stackTrace.forEach { sb.appendLine("  $it") }
        var c = e.cause
        var depth = 0
        while (c != null && depth < 5) {
            sb.appendLine()
            sb.appendLine("--- 原因 ${++depth} ---")
            sb.appendLine("${c.javaClass.name}: ${c.message}")
            c.stackTrace.take(15).forEach { sb.appendLine("  $it") }
            c = c.cause
        }
        sb.appendLine()
        val c2 = ctxRef
        if (c2 != null) {
            sb.appendLine("--- 环境 ---")
            try {
                sb.appendLine("proot: ${Proot.prootBin(c2).absolutePath} 存在=${Proot.ready(c2)}")
                sb.appendLine("rootfs: ${Proot.rootfs(c2).absolutePath} bash=${File(Proot.rootfs(c2), "bin/bash").exists()}")
            } catch (_: Throwable) {}
        }
        sb.appendLine()
        sb.appendLine("--- 最近日志 ---")
        sb.appendLine(LogBus.text().takeLast(4000))
        sb.appendLine()
        f.appendText(sb.toString())
    }

    fun record(msg: String, e: Throwable? = null) {
        try {
            val f = file()
            f.parentFile?.mkdirs()
            val sb = StringBuilder()
            sb.appendLine("========== ${SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())} ==========")
            sb.appendLine(msg)
            if (e != null) {
                sb.appendLine("${e.javaClass.name}: ${e.message}")
                e.stackTrace.take(20).forEach { sb.appendLine("  $it") }
            }
            f.appendText(sb.toString() + "\n")
        } catch (_: Throwable) {}
    }
}
