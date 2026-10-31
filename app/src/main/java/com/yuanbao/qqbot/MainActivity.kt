package com.yuanbao.qqbot

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.Spannable
import android.text.SpannableString
import android.text.style.ForegroundColorSpan
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.progressindicator.LinearProgressIndicator
import kotlin.concurrent.thread
import org.json.JSONObject
import java.io.File

class MainActivity : AppCompatActivity() {

    // ===== 原有字段 =====
    private lateinit var tvLog: TextView
    private lateinit var etQQ: EditText
    private lateinit var svLog: ScrollView

    // ===== 新增：进度条 =====
    private lateinit var progressRow: View
    private lateinit var tvProgress: TextView
    private lateinit var tvProgressPct: TextView
    private lateinit var progressBar: LinearProgressIndicator

    // ===== 新增：状态卡的灯与值 =====
    private lateinit var dotRootfs: View
    private lateinit var dotQq: View
    private lateinit var dotSnow: View
    private lateinit var dotPayload: View
    private lateinit var dotAgent: View
    private lateinit var tvStRootfs: TextView
    private lateinit var tvStQq: TextView
    private lateinit var tvStSnow: TextView
    private lateinit var tvStPayload: TextView
    private lateinit var tvStAgent: TextView

    /** 触发 DeployService 的按钮，忙碌时整体禁用 */
    private lateinit var actionButtons: List<Button>

    private val ui = Handler(Looper.getMainLooper())

    /**
     * 兜底：万一收不到「== 完成 ==」也要把界面解开放出来。
     * 解锁前先在日志里说明一声，不能静默恢复——否则用户以为动作已经结束，
     * 再去点一次就会重复触发（这一步可能其实还在后台跑）。
     */
    private val busyTimeout = Runnable {
        if (busyAct != null) {
            LogBus.log("⚠ 等待超时，已恢复按钮（可能上一步还没真正结束）")
            endBusy()
        }
    }

    /** 当前正在跑的动作，null 表示空闲 */
    private var busyAct: String? = null

    private val logListener: (String) -> Unit = { line ->
        if (!isDestroyed && ::tvLog.isInitialized) {
            appendLog(line)
            onLogLine(line)
            val t = tvLog.text
            if (t.length > 80_000) tvLog.text = t.takeLast(40_000)
            svLog.post { if (!isDestroyed) svLog.fullScroll(View.FOCUS_DOWN) }
        }
    }

    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        try {
            CrashHandler.install(this)
            setContentView(R.layout.activity_main)
        } catch (e: Throwable) {
            CrashHandler.record("MainActivity.setContentView", e)
            throw e
        }
        tvLog = findViewById(R.id.tvLog)
        etQQ = findViewById(R.id.etQQ)
        svLog = findViewById(R.id.svLog)

        progressRow = findViewById(R.id.rowProgress)
        tvProgress = findViewById(R.id.tvProgress)
        tvProgressPct = findViewById(R.id.tvProgressPct)
        progressBar = findViewById(R.id.progress)

        dotRootfs = findViewById(R.id.dotRootfs)
        dotQq = findViewById(R.id.dotQq)
        dotSnow = findViewById(R.id.dotSnow)
        dotPayload = findViewById(R.id.dotPayload)
        dotAgent = findViewById(R.id.dotAgent)
        tvStRootfs = findViewById(R.id.tvStRootfs)
        tvStQq = findViewById(R.id.tvStQq)
        tvStSnow = findViewById(R.id.tvStSnow)
        tvStPayload = findViewById(R.id.tvStPayload)
        tvStAgent = findViewById(R.id.tvStAgent)

        actionButtons = listOf(
            findViewById(R.id.btnDeploy),
            findViewById(R.id.btnStart),
            findViewById(R.id.btnStop),
            findViewById(R.id.btnStatus),
            findViewById(R.id.btnVer),
            findViewById(R.id.btnDiag)
        )

        try { askPerms() } catch (_: Throwable) {}

        LogBus.listen(logListener)
        try {
            val old = LogBus.text()
            if (old.isNotEmpty()) {
                // 重新着色回灌：LogBus 缓冲里是逐行存的，按行 append 以便复用着色逻辑
                for (l in old.split('\n')) if (l.isNotEmpty()) appendLog(l)
            }
        } catch (_: Throwable) {}

        findViewById<Button>(R.id.btnDeploy).setOnClickListener {
            val src = etQQ.text.toString().trim()
            if (src.isEmpty()) {
                fire(DeployService.DEPLOY, "")
            } else {
                if (!ensureStorageForLocalPath(src)) return@setOnClickListener
                fire(DeployService.DEPLOY, src)
            }
        }

        findViewById<Button>(R.id.btnStart).setOnClickListener { fire(DeployService.START) }
        findViewById<Button>(R.id.btnStop).setOnClickListener { fire(DeployService.STOP) }
        findViewById<Button>(R.id.btnStatus).setOnClickListener { fire(DeployService.STATUS) }
        findViewById<Button>(R.id.btnVer).setOnClickListener { fire(DeployService.VERSIONS) }
        findViewById<Button>(R.id.btnDiag).setOnClickListener { fire(DeployService.DIAG) }

        findViewById<Button>(R.id.btnConsole).setOnClickListener {
            WebActivity.open(this, "控制台", "http://127.0.0.1:${Cfg.AGENT_PORT}/")
        }
        findViewById<Button>(R.id.btnVnc).setOnClickListener {
            WebActivity.open(this, "扫码登录", "http://127.0.0.1:${Cfg.NOVNC_PORT}/vnc.html?autoconnect=true")
        }
        findViewById<Button>(R.id.btnKeep).setOnClickListener { showKeepAlive() }
        findViewById<Button>(R.id.btnCrash).setOnClickListener { showCrash() }

        try { checkProot() } catch (e: Throwable) {
            tvLog.append("proot 检查失败：${e.message}\n")
        }
        try {
            val cf = CrashHandler.file()
            if (cf.exists() && cf.length() > 0) {
                tvLog.append("\n\n【检测到上次崩溃记录，已存到 ${cf.absolutePath}】\n")
                tvLog.append(cf.readText().takeLast(2500))
                tvLog.append("\n")
            }
        } catch (_: Throwable) {}

        refreshStatus()
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
    }

    override fun onDestroy() {
        ui.removeCallbacks(busyTimeout)
        LogBus.unlisten(logListener)
        super.onDestroy()
    }

    // ================= 日志着色 =================

    /** 按行首语义符号决定颜色；只给「新追加的这一行」建 Span，不做全量重建 */
    private fun appendLog(line: String) {
        val color = ContextCompat.getColor(this, logColorRes(line))
        val ss = SpannableString(line + "\n")
        ss.setSpan(ForegroundColorSpan(color), 0, ss.length, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        tvLog.append(ss)
    }

    private fun logColorRes(line: String): Int {
        val t = line.trimStart()
        return when {
            t.startsWith("✓") -> R.color.logOk
            t.startsWith("✗") -> R.color.logErr
            t.startsWith("⚠") -> R.color.logWarn
            else -> R.color.logDim
        }
    }

    // ================= 忙碌态 / 进度 =================

    /** 日志回调里顺手做的两件事：推进度条、判定动作完成 */
    private fun onLogLine(line: String) {
        val act = busyAct ?: return
        if (line.trimStart().startsWith(DONE_PREFIX)) {
            endBusy()
            return
        }
        // DeployService.go() 启动失败时不会打「完成」行，这里立刻解锁，不等兜底超时。
        //
        // 注意：这里必须用「行首 ✗ + 服务启动失败」判定，不能图省事只写
        // line.contains("服务启动失败")。因为 DeployService.onCreate() 的
        // startForeground 降级分支会打一条【非致命】告警：
        //     ⚠ 前台服务启动失败：xxx（不影响部署，但更容易被系统回收）
        // 它只是「通知栏降级」，部署线程仍在正常往下跑，动作并未结束。
        // 若按子串匹配把它当成结束信号，按钮会在部署进行到一半被提前解锁，
        // 用户可重复点击「一键部署」造成重复触发。
        // 真正的致命失败只有 DeployService.go() 里 catch 到 startService 抛异常时打的
        //     ✗ 服务启动失败：xxx
        // ——那代表动作根本没跑起来（也就不会再有「== 完成：」行），才可以解锁。
        if (line.trimStart().startsWith(SERVICE_START_FAIL_PREFIX)) {
            endBusy()
            return
        }
        if (act == DeployService.DEPLOY) {
            val step = STEP_RE.find(line)?.groupValues?.getOrNull(1)?.toIntOrNull()
            if (step != null) setProgress(step.coerceIn(0, TOTAL_STEPS), line.trim())
        }
    }

    private fun setProgress(step: Int, text: String) {
        val pct = (step * 100 / TOTAL_STEPS).coerceIn(0, 100)
        progressBar.progress = pct
        tvProgress.text = text
        tvProgressPct.text = "$pct%"
    }

    private fun beginBusy(act: String) {
        ui.removeCallbacks(busyTimeout)
        busyAct = act
        ui.postDelayed(
            busyTimeout,
            if (act == DeployService.DEPLOY) BUSY_TIMEOUT_DEPLOY_MS else BUSY_TIMEOUT_OTHER_MS
        )
        actionButtons.forEach { it.isEnabled = false }
        if (act == DeployService.DEPLOY) {
            progressRow.visibility = View.VISIBLE
            progressBar.progress = 0
            tvProgress.text = getString(R.string.progress_prepare)
            tvProgressPct.text = getString(R.string.progress_idle)
        } else {
            progressRow.visibility = View.GONE
        }
    }

    private fun endBusy() {
        if (busyAct == null) return
        busyAct = null
        ui.removeCallbacks(busyTimeout)
        actionButtons.forEach { it.isEnabled = true }
        progressRow.visibility = View.GONE
        refreshStatus()
    }

    // ================= 组件状态卡 =================

    private enum class Level { OK, WARN, OFF, ERR }

    private data class Probe(val level: Level, val text: String)

    private data class Snapshot(
        val rootfs: Probe,
        val qq: Probe,
        val snow: Probe,
        val payload: Probe,
        val agent: Probe
    )

    /**
     * 状态卡完全不需要进容器跑命令 —— rootfs 就在 filesDir/rootfs 下，
     * 用 Java File API 直接看，毫秒级。真正的文件读取放在后台线程，
     * 主线程只负责 setText，避免任何卡顿。
     */
    private fun refreshStatus() {
        thread(name = "status-card") {
            val snap = probeStatus()
            if (isDestroyed || isFinishing) return@thread
            runOnUiThread {
                if (isDestroyed || isFinishing) return@runOnUiThread
                applyStatus(snap)
            }
        }
    }

    private fun probeStatus(): Snapshot {
        val root = Proot.rootfs(this)
        return Snapshot(
            rootfs = probeRootfs(root),
            qq = probeQQ(root),
            snow = probeSnowLuma(root),
            payload = probePayload(root),
            agent = probeAgent(root)
        )
    }

    private fun probeRootfs(root: File): Probe = try {
        if (File(root, "bin/bash").exists()) Probe(Level.OK, "就绪")
        else Probe(Level.OFF, "未部署")
    } catch (e: Throwable) {
        Probe(Level.ERR, getString(R.string.st_unknown))
    }

    private fun probeQQ(root: File): Probe = try {
        val f = File(root, "opt/QQ/resources/app/package.json")
        if (!f.exists()) {
            Probe(Level.OFF, "未安装")
        } else {
            val v = jsonField(f.readText(), "version").orEmpty()
            when {
                v.isBlank() -> Probe(Level.WARN, "版本未知")
                v == QQ_EXPECT -> Probe(Level.OK, v)
                else -> Probe(Level.WARN, "$v（期望 $QQ_EXPECT）")
            }
        }
    } catch (e: Throwable) {
        Probe(Level.ERR, "读取失败")
    }

    private fun probeSnowLuma(root: File): Probe = try {
        val f = File(root, "opt/snowluma/release.json")
        if (!f.exists()) {
            Probe(Level.OFF, "未安装")
        } else {
            val txt = f.readText()
            val v = jsonField(txt, "version").orEmpty()
            val target = jsonField(txt, "target").orEmpty()
            if (v.isBlank()) {
                Probe(Level.WARN, if (target.isBlank()) "版本未知" else "target $target")
            } else {
                Probe(Level.OK, if (target.isBlank()) "v$v" else "v$v · $target")
            }
        }
    } catch (e: Throwable) {
        Probe(Level.ERR, "读取失败")
    }

    private fun probePayload(root: File): Probe = try {
        val f = File(root, "opt/qqstack/libsnowluma_linux_resident_dispatch.so")
        when {
            !f.exists() -> Probe(Level.OFF, "未导出")
            f.length() <= 0L -> Probe(Level.WARN, "空文件")
            else -> Probe(Level.OK, "已导出")
        }
    } catch (e: Throwable) {
        Probe(Level.ERR, getString(R.string.st_unknown))
    }

    private fun probeAgent(root: File): Probe = try {
        // QQ Agent 是 TypeScript 项目：就绪标志是 package.json + src/index.ts（不是老的 src/server.js）
        if (File(root, "opt/qqagent/package.json").exists() && File(root, "opt/qqagent/src/index.ts").exists())
            Probe(Level.OK, "就绪")
        else Probe(Level.OFF, "未安装")
    } catch (e: Throwable) {
        Probe(Level.ERR, getString(R.string.st_unknown))
    }

    /** 极小 JSON：优先 org.json（系统自带，无需新增依赖），解析不了再退回正则 */
    private fun jsonField(text: String, key: String): String? = try {
        val v = JSONObject(text).optString(key, "")
        if (v.isBlank()) null else v.trim()
    } catch (e: Throwable) {
        val m = Regex("\"$key\"\\s*:\\s*\"([^\"]+)\"").find(text)
        m?.groupValues?.getOrNull(1)?.trim()?.takeIf { it.isNotBlank() }
    }

    private fun applyStatus(s: Snapshot) {
        bindRow(dotRootfs, tvStRootfs, s.rootfs)
        bindRow(dotQq, tvStQq, s.qq)
        bindRow(dotSnow, tvStSnow, s.snow)
        bindRow(dotPayload, tvStPayload, s.payload)
        bindRow(dotAgent, tvStAgent, s.agent)
    }

    private fun bindRow(dot: View, tv: TextView, p: Probe) {
        dot.setBackgroundResource(dotRes(p.level))
        tv.text = p.text
        tv.setTextColor(ContextCompat.getColor(this, textRes(p.level)))
    }

    private fun dotRes(l: Level): Int = when (l) {
        Level.OK -> R.drawable.dot_ok
        Level.WARN -> R.drawable.dot_warn
        Level.ERR -> R.drawable.dot_err
        Level.OFF -> R.drawable.dot_off
    }

    private fun textRes(l: Level): Int = when (l) {
        Level.OK -> R.color.stateOk
        Level.WARN -> R.color.stateWarn
        Level.ERR -> R.color.stateErr
        Level.OFF -> R.color.textDim
    }

    // ================= 原有业务逻辑（行为不变） =================

    private fun showCrash() {
        val cf = CrashHandler.file()
        val txt = if (cf.exists() && cf.length() > 0) cf.readText() else "（暂无崩溃记录）"
        MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.dlg_crash_title, cf.absolutePath))
            .setMessage(txt.takeLast(6000))
            .setNeutralButton(R.string.dlg_crash_copy) { _, _ ->
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("crash", txt))
                Toast.makeText(this, R.string.toast_copied, Toast.LENGTH_SHORT).show()
            }
            .setPositiveButton(R.string.dlg_crash_close, null)
            .show()
    }

    private fun checkProot() {
        if (!Proot.ready(this)) {
            LogBus.log("⚠ 这个 APK 里没打包 proot：构建前请先执行 python3 tools/fetch-proot.py")
        } else {
            LogBus.log("· proot 就绪：${Proot.prootBin(this).absolutePath}")
            LogBus.log("· 点「一键部署」开始；路径留空会自动下载 QQ 3.2.32 arm64")
        }
    }

    private fun fire(act: String, src: String = "") {
        tvLog.append("\n== $act ==\n")
        beginBusy(act)
        DeployService.go(this, act, src)
    }

    private fun askPerms() {
        val need = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED) need.add(Manifest.permission.POST_NOTIFICATIONS)
        if (Build.VERSION.SDK_INT <= 32 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE)
            != PackageManager.PERMISSION_GRANTED) need.add(Manifest.permission.READ_EXTERNAL_STORAGE)
        if (need.isNotEmpty()) ActivityCompat.requestPermissions(this, need.toTypedArray(), 1)
    }

    private fun ensureStorageForLocalPath(src: String): Boolean {
        if (src.isEmpty() || src.startsWith("http")) return true
        if (Build.VERSION.SDK_INT < 30) return true
        if (Environment.isExternalStorageManager()) return true
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.dlg_storage_title)
            .setMessage(R.string.dlg_storage_msg)
            .setPositiveButton(R.string.dlg_storage_go) { _, _ ->
                try {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                    )
                } catch (_: Exception) {
                    try { startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)) }
                    catch (_: Exception) {}
                }
            }
            .setNegativeButton(R.string.dlg_cancel, null)
            .show()
        return false
    }

    private fun showKeepAlive() {
        val cmds = listOf(
            "adb shell device_config set_sync_disabled_for_tests persistent",
            "adb shell device_config put activity_manager max_phantom_processes 2147483647",
            "adb shell settings put global settings_enable_monitor_phantom_procs false",
            "adb shell dumpsys deviceidle whitelist +com.yuanbao.qqbot"
        )
        val text = """
            容器 App 也一样要过安卓这道关，三件事：

            1) 电池优化：系统设置 → 应用 → 本 App → 电池 → 选「不受限制」。

            2) 幽灵进程杀手（Android 12+ 必做，QQ 的 Chromium 子进程一开就超限，会被静默杀掉）：
               用「无线调试」或 LADB / Shizuku 拿到 adb 后执行下面 4 条（只需一次）。

            3) 保持通知可见：本 App 已用前台服务常驻通知，别把它滑掉。

            ${cmds.joinToString("\n            ")}
        """.trimIndent()
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.dlg_keep_title)
            .setMessage(text)
            .setNeutralButton(R.string.dlg_keep_copy) { _, _ ->
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("adb", cmds.joinToString("\n")))
                Toast.makeText(this, R.string.toast_copied, Toast.LENGTH_SHORT).show()
            }
            .setPositiveButton(R.string.dlg_keep_ok, null)
            .show()
    }

    companion object {
        /** QQ 必须是这个版本，协议端才对得上 */
        private const val QQ_EXPECT = "3.2.32-52194"

        /** DeployService.deploy() 一共 9 步 */
        private const val TOTAL_STEPS = 9

        /**
         * 兜底超时：只在收不到「== 完成：」/「✗ 服务启动失败」时才兜底解锁，
         * 所以取值要略大于部署的正常耗时，避免部署跑到一半被误解锁。
         *
         * - deploy：[4/9] 那步 apt 装包官方说明最慢 5~15 分钟，加上下载 / 解压 / 其它步骤，
         *   整体通常在 20 分钟内收尾，这里给 20 分钟留足余量（原来 45 分钟太保守，
         *   万一真没收到完成信号，界面会长时间不可操作）。
         * - 其它动作（start / stop / status / versions / diag）：都是秒级或几十秒，3 分钟足够。
         *
         * 常量显式以 1000L 收尾，全程 Long 运算（1200 * 1000L = 1_200_000L），不会整数溢出。
         */
        private const val BUSY_TIMEOUT_DEPLOY_MS = 20 * 60 * 1000L
        private const val BUSY_TIMEOUT_OTHER_MS = 3 * 60 * 1000L

        /** DeployService 打的 [4/9] 这种步骤行 */
        private val STEP_RE = Regex("\\[(\\d{1,2})/9\\]")

        /** DeployService.run() 的 finally 里打的收尾行 */
        private const val DONE_PREFIX = "== 完成："

        /**
         * DeployService.go() 里 startService 抛异常时打的致命失败行（动作根本没跑起来）。
         * 必须带行首的 ✗ 一起判定，用于和 onCreate() 里那条非致命的
         *「⚠ 前台服务启动失败」区分开——后者不代表动作结束，不能解锁。
         */
        private const val SERVICE_START_FAIL_PREFIX = "✗ 服务启动失败"
    }
}
