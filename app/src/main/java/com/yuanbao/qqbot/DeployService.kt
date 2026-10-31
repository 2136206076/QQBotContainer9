package com.yuanbao.qqbot

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
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

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        CrashHandler.install(this)
        try {
            val pm = getSystemService(PowerManager::class.java)
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "qqbot:deploy").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
        } catch (e: Throwable) {
            CrashHandler.record("WakeLock 获取失败", e)
        }
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
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(1, n)
            }
        } catch (e: Throwable) {
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

    override fun onDestroy() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {}
        super.onDestroy()
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

    /** 结果清单里的一行：就绪打 ✓，没就绪打 ✗ 并给出下一步该做什么。 */
    private fun reportComponent(name: String, ok: Boolean, fix: String) {
        if (ok) {
            LogBus.log("  ✓ $name：已就绪")
        } else {
            LogBus.log("  ✗ $name：未就绪 → $fix")
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
        val agentOk = Installer.installAgent(this)
        if (!agentOk) LogBus.log("⚠ QQ Agent 未就绪（可稍后重试）")

        LogBus.log("[6/9] 装 SnowLuma（协议端）")
        val snowOk = Installer.installSnowLuma(this)
        if (!snowOk) LogBus.log("⚠ SnowLuma 未就绪（可稍后重试）")

        LogBus.log("[7/9] 装 Linux 版 QQ（必须是 3.2.32-52194）")
        val qqOk = Installer.installQQ(this, qqSrc)
        if (!qqOk) {
            LogBus.log("⚠ QQ 没装好。留空会自动下；也可填本地 deb 路径或直链后重跑部署")
        }

        LogBus.log("[8/9] 打补丁 / 建路径别名 / 冻结热更新")
        Installer.patchAndFinish(this)

        LogBus.log("[9/9] 拉起：虚拟屏 → 协议端 → QQ → 控制台")
        Installer.vncPassword(this, "12345678")
        Installer.start(this)

        // ===== 本次部署结果清单 =====
        // 5/6/7 步失败时只打一句 ⚠、不中断流程，所以 9 步跑完直接打「部署结束」很容易
        // 让人误以为全好了。这里把每一步的真实结果摊开：就绪的 ✓，没就绪的 ✗ + 该做什么。
        LogBus.log("========== 本次部署结果（清单）==========")
        reportComponent("QQ Agent（大脑）", agentOk,
            "重跑部署；或手动：cd /opt/qqagent && npm install（必须全量，tsx 是 devDependency）" +
            " && npm run build，再 node dist/src/index.js（或 ./node_modules/.bin/tsx src/index.ts）试起")
        reportComponent("SnowLuma（协议端）", snowOk,
            "重跑部署；或手动下 SnowLuma-v2.1.1-linux-arm64.tar.gz 解到 /opt/snowluma（版本要和 QQ 配对）")
        reportComponent("Linux 版 QQ", qqOk,
            "QQ 没装好 → 留空会自动下载，或在上方填本地 deb 路径/直链后重跑部署（须 3.2.32-52194 arm64）")
        LogBus.log("  · 补丁/别名/热更新屏蔽/载荷导出：看上面 [8/9] 的输出")
        LogBus.log("  · /proc/locks 补丁走的是方案 A 还是方案 B：cat ${Cfg.STACK}/.locks-patch-method")
        LogBus.log("  · 三大件当前状态复核：bash ${Cfg.STACK}/scripts/versions.sh")
        LogBus.log(if (agentOk && snowOk && qqOk)
            "  ✓ 三大件都已就绪，可以去扫码登录了"
        else
            "  ⚠ 上面有组件没就绪 —— 这一轮**不算部署成功**，按提示补齐后重跑部署")

        LogBus.log("""
            ========== 部署结束 ==========
            控制台 http://127.0.0.1:${Cfg.AGENT_PORT}
            扫码   http://127.0.0.1:${Cfg.NOVNC_PORT}/vnc.html  （VNC 密码 12345678）
            协议端 http://127.0.0.1:${Cfg.SLWEBUI_PORT}
            下一步：点下面的「扫码登录」看二维码，再点「控制台」配模型和白名单
        """.trimIndent())
    }
}
