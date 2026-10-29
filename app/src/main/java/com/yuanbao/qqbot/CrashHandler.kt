package com.yuanbao.qqbot

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 崩溃捕获：App 闪退时把完整堆栈写到文件，不用连电脑抓 logcat。
 * 落盘位置（按可写性依次尝试）：
 *   /sdcard/Download/qqbot-crash.txt
 *   filesDir/crash.txt
 */
object CrashHandler {

    private var dir: File? = null

    fun install(ctx: Context) {
        dir = pickDir(ctx)
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try { save(t, e) } catch (_: Throwable) {}
            prev?.uncaughtException(t, e)
        }
    }

    private fun pickDir(ctx: Context): File {
        val sd = File("/sdcard/Download")
        if (sd.isDirectory && sd.canWrite()) return sd
        return ctx.filesDir
    }

    fun file(): File = File(dir ?: File("/sdcard/Download"), "qqbot-crash.txt")

    private fun save(t: Thread, e: Throwable) {
        val f = file()
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
        sb.appendLine("--- 环境 ---")
        try {
            sb.appendLine("proot: ${Proot.prootBin(QQBotApp.ctx).absolutePath} 存在=${Proot.ready(QQBotApp.ctx)}")
            sb.appendLine("rootfs: ${Proot.rootfs(QQBotApp.ctx).absolutePath} 存在=${File(Proot.rootfs(QQBotApp.ctx), "bin/bash").exists()}")
        } catch (_: Throwable) {}
        sb.appendLine()
        sb.appendLine("--- 最近日志 ---")
        sb.appendLine(LogBus.text().takeLast(4000))
        sb.appendLine()
        f.appendText(sb.toString())
    }

    /** 手动记录一条（比如某个步骤失败） */
    fun record(msg: String, e: Throwable? = null) {
        try {
            val sb = StringBuilder()
            sb.appendLine("========== ${SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())} ==========")
            sb.appendLine(msg)
            if (e != null) {
                sb.appendLine("${e.javaClass.name}: ${e.message}")
                e.stackTrace.take(20).forEach { sb.appendLine("  $it") }
            }
            file().appendText(sb.toString() + "\n")
        } catch (_: Throwable) {}
    }
}
