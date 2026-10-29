package com.yuanbao.qqbot

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlin.concurrent.thread

class DeployService : Service() {

    companion object {
        const val ACT = "act"
        const val DEPLOY = "deploy"
        const val START = "start"
        const val STOP = "stop"
        const val STATUS = "status"
        const val VERSIONS = "versions"
        const val DIAG = "diag"
        const val QQ_SRC = "qq_src"
        const val CH = "qqbot"

        fun go(ctx: Context, act: String, qqSrc: String = "") {
            val i = Intent(ctx, DeployService::class.java)
                .putExtra(ACT, act).putExtra(QQ_SRC, qqSrc)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Throwable) {
                CrashHandler.record("启动服务失败", e)
                LogBus.log("✗ 服务启动失败：${e.javaClass.simpleName}: ${e.message}")
                LogBus.log("  常见原因：电池优化限制了后台启动。去系统设置把本 App 设为「不受限制」")
            }
        }
    }

    override fun onBind(i: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        try {
            val nm = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CH) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CH, "QQ 机器人容器", NotificationManager.IMPORTANCE_LOW)
                )
            }
            val n: Notification = NotificationCompat.Builder(this, CH)
                .setContentTitle("QQ 机器人容器")
                .setContentText("正在运行，保持这个通知可显著降低被系统回收的概率")
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setOngoing(true)
                .build()
            startForeground(1, n)
        } catch (e: Throwable) {
            // 通知权限没给 / 前台服务受限：不要让整个 App 崩掉，降级继续跑
            CrashHandler.record("startForeground 失败（前台服务降级，不影响部署逻辑）", e)
            LogBus.log("⚠ 前台服务启动失败：${e.message}（不影响部署，但更容易被系统回收）")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val act = intent?.getStringExtra(ACT) ?: START
        val qqSrc = intent?.getStringExtra(QQ_SRC) ?: ""
        thread(name = "deploy-$act") {
            try { run(act, qqSrc) } catch (e: Throwable) {
                CrashHandler.record("执行 $act 时异常", e)
                LogBus.log("✗ 异常：${e.javaClass.simpleName}: ${e.message}")
                e.stackTrace.take(6).forEach { LogBus.log("    at $it") }
            } finally { LogBus.log("== 完成：$act ==") }
        }
        return START_STICKY
    }

    private fun run(act: String, qqSrc: String) {
        val err = Proot.prepare(this)
        if (err != null) { LogBus.log("✗ $err"); return }

        when (act) {
            DEPLOY -> deploy(qqSrc)
            START -> { LogBus.log("▶ 拉起整条链路…"); Installer.start(this) }
            STOP -> { LogBus.log("■ 停止…"); Installer.stop(this) }
            STATUS -> Installer.status(this)
            VERSIONS -> Installer.versions(this)
            DIAG -> Installer.diag(this)
        }
    }

    private fun deploy(qqSrc: String) {
        LogBus.log("========== 一键部署开始 ==========")
        LogBus.log("· proot: ${Proot.prootBin(this).absolutePath}")

        LogBus.log("[1/9] 准备 Ubuntu 根文件系统")
        var gotRootfs = false
        for (url in Cfg.ROOTFS_URLS) {
            LogBus.log("↓ 尝试 $url")
            if (Installer.ensureRootfs(this, url)) { gotRootfs = true; break }
            LogBus.log("· 这个源不通，换下一个")
        }
        if (!gotRootfs) { LogBus.log("✗ rootfs 下载/解压都失败了，检查网络后重试"); return }

        LogBus.log("[2/9] 写入网络/热更新屏蔽配置")
        Installer.seed(this)

        LogBus.log("[3/9] 放入部署脚本")
        Installer.installScripts(this)

        LogBus.log("[4/9] 装系统包 / Node / 编译 hook 载入器")
        if (!Installer.bootstrap(this)) { LogBus.log("✗ 卡在这一步，看上面报错"); return }

        LogBus.log("[5/9] 装 QQ Agent（大脑）")
        if (!Installer.installAgent(this)) LogBus.log("⚠ QQ Agent 未就绪（可稍后重试）")

        LogBus.log("[6/9] 装 SnowLuma（协议端）")
        if (!Installer.installSnowLuma(this)) LogBus.log("⚠ SnowLuma 未就绪（可稍后重试）")

        LogBus.log("[7/9] 装 Linux 版 QQ（必须是 3.2.32-52194）")
        if (!Installer.installQQ(this, qqSrc)) {
            LogBus.log("⚠ QQ 没装好。把 3.2.32-52194 的 deb/tar.gz 放到手机，在上方填路径或 URL 后重跑部署")
        }

        LogBus.log("[8/9] 打补丁 / 建路径别名 / 冻结热更新")
        Installer.patchAndFinish(this)

        LogBus.log("[9/9] 拉起：虚拟屏 → 协议端 → QQ → 控制台")
        Installer.vncPassword(this, "12345678")
        Installer.start(this)

        LogBus.log("""
            ========== 部署结束 ==========
            控制台 http://127.0.0.1:${Cfg.AGENT_PORT}
            扫码   http://127.0.0.1:${Cfg.NOVNC_PORT}/vnc.html  （VNC 密码 12345678）
            协议端 http://127.0.0.1:${Cfg.SLWEBUI_PORT}
            下一步：点下面的「扫码登录」看二维码，再点「控制台」配模型和白名单
        """.trimIndent())
    }
}
