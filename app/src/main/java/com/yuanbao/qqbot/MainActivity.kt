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
import android.provider.Settings
import android.view.View
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {

    private lateinit var tvLog: TextView
    private lateinit var etQQ: EditText
    private lateinit var svLog: ScrollView

    private val logListener: (String) -> Unit = { line ->
        if (!isDestroyed && ::tvLog.isInitialized) {
            tvLog.append(line + "\n")
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

        try { askPerms() } catch (_: Throwable) {}

        LogBus.listen(logListener)
        try {
            val old = LogBus.text()
            if (old.isNotEmpty()) tvLog.append(old)
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
    }

    override fun onDestroy() {
        LogBus.unlisten(logListener)
        super.onDestroy()
    }

    private fun showCrash() {
        val cf = CrashHandler.file()
        val txt = if (cf.exists() && cf.length() > 0) cf.readText() else "（暂无崩溃记录）"
        AlertDialog.Builder(this)
            .setTitle("崩溃日志 —— ${cf.absolutePath}")
            .setMessage(txt.takeLast(6000))
            .setNeutralButton("复制全部") { _, _ ->
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("crash", txt))
                Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show()
            }
            .setPositiveButton("关闭", null)
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
        AlertDialog.Builder(this)
            .setTitle("需要访问本地文件")
            .setMessage("Android 11+ 读取 /sdcard 上的 QQ 安装包需要「所有文件访问」权限。去系统设置打开后，再点一次「一键部署」。")
            .setPositiveButton("去设置") { _, _ ->
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
            .setNegativeButton("取消", null)
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
        AlertDialog.Builder(this)
            .setTitle("保活")
            .setMessage(text)
            .setNeutralButton("复制 adb 命令") { _, _ ->
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("adb", cmds.joinToString("\n")))
                Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show()
            }
            .setPositiveButton("知道了", null)
            .show()
    }
}
