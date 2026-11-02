package com.yuanbao.qqbot

import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 把「运行日志 + 组件状态 + 崩溃记录」打包成一个纯文本文件。
 *
 * 落两处：
 * 1) 外部私有目录 getExternalFilesDir(null)/logs —— 这是唯一可信产物，
 *    FileProvider 分享用的就是它（私有目录不需要任何运行时权限）。
 * 2) 公共「下载/Q鱼罐头」 —— 纯便利副本，用户拿文件管理器就能找到并拖给开发者。
 *    这份失败（厂商 ROM 拦 MediaStore、目录不可写）绝不影响整体成败。
 *
 * 文件头里塞满诊断信息（机型 / ABI / **真实签名指纹**）：用户贴回来的日志
 * 自带定位线索，省掉一轮「你什么机型 / 哪个包」的追问。签名指纹尤其关键 ——
 * 历史上 CI 每次重签导致覆盖安装失败，就是靠它一眼看出来的。
 */
object LogExporter {

    /** 私有目录下的子目录名，必须与 res/xml/file_paths.xml 的 path 对齐 */
    private const val DIR_NAME = "logs"

    /** 公共下载目录下的子文件夹名 */
    private const val PUBLIC_FOLDER = "Q鱼罐头"

    private val HEX = "0123456789ABCDEF".toCharArray()

    /**
     * 导出一次日志。
     *
     * 加了 @Synchronized：连点两次会拿到同一个时间戳，两个线程同时写同一个文件
     * 会出现交错内容；串行化最省事（一次导出不到几十毫秒，排队没感知）。
     * IO 本身仍由调用方放到后台线程，这里不切线程。
     *
     * @param ctx 任意 Context，内部只用 application 级别的能力
     * @param snapshot 组件状态文本，由调用方（MainActivity）拼好传进来
     * @return 私有目录里的文件；连私有目录都写不进去时返回 null
     */
    @Synchronized
    fun export(ctx: Context, snapshot: String): File? {
        val now = Date()
        val name = "qfish-log-" +
            SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(now) + ".txt"
        val bytes = buildContent(ctx, snapshot, now).toByteArray(Charsets.UTF_8)

        // 私有目录那份必须成功，否则没有可分享的产物，直接返回失败让 UI 报错
        val privateFile = writePrivate(ctx, name, bytes) ?: return null

        // 公共目录那份是锦上添花，任何异常都只吞掉、不影响返回值
        try {
            writePublicCopy(ctx, name, bytes)
        } catch (_: Throwable) {
        }
        return privateFile
    }

    // ================= 文本拼装 =================

    private fun buildContent(ctx: Context, snapshot: String, now: Date): String {
        val pm = ctx.packageManager
        val pkg = ctx.packageName
        val pi = packageInfo(ctx)

        // 应用名走系统 label，改了 strings.xml 不用同步改这里；取不到再用兜底常量
        val appName = try {
            ctx.applicationInfo?.loadLabel(pm)?.toString()?.takeIf { it.isNotBlank() } ?: "Q鱼罐头"
        } catch (_: Throwable) {
            "Q鱼罐头"
        }
        val versionName = pi?.versionName?.takeIf { it.isNotBlank() } ?: "?"

        val sb = StringBuilder()
        sb.appendLine("=== Q鱼罐头 运行日志 ===")
        sb.append("导出时间 : ")
            .appendLine(SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(now))
        sb.append("应用      : ")
            .append(appName).append(' ').append(versionName)
            .append(" (versionCode ").append(versionCodeOf(pi)).appendLine(")")
        sb.append("包名      : ").appendLine(pkg)
        sb.append("签名SHA256: ").appendLine(signatureSha256(ctx))
        sb.append("设备      : ").appendLine(deviceLine())
        sb.append("ABI       : ").appendLine(abiLine())
        sb.appendLine("-------- 组件状态 --------")
        sb.appendLine(snapshot)
        sb.appendLine("-------- 运行日志 --------")
        sb.appendLine(LogBus.text())
        sb.appendLine("-------- 崩溃记录 --------")
        sb.appendLine(crashText())
        return sb.toString()
    }

    private fun deviceLine(): String {
        val manufacturer = Build.MANUFACTURER?.takeIf { it.isNotBlank() } ?: "未知厂商"
        val model = Build.MODEL?.takeIf { it.isNotBlank() } ?: "未知机型"
        val release = Build.VERSION.RELEASE?.takeIf { it.isNotBlank() } ?: "?"
        return "$manufacturer $model / Android $release (SDK ${Build.VERSION.SDK_INT})"
    }

    /** 只留前 3 个 ABI：再多也没信息量，只会把文件头撑长 */
    private fun abiLine(): String {
        val abis = Build.SUPPORTED_ABIS
        if (abis == null || abis.isEmpty()) return "未知"
        return abis.take(3).joinToString(", ")
    }

    private fun crashText(): String = try {
        val f = CrashHandler.file()
        if (f.exists() && f.length() > 0L) f.readText() else "（无）"
    } catch (_: Throwable) {
        // 崩溃文件读不出来（权限 / 编码）时不能连累整份日志
        "（无）"
    }

    // ================= 签名指纹 =================

    /**
     * 取当前 APK 的签名证书 SHA-256（冒号分隔大写）。
     *
     * 这条信息是排障核心：CI 每次重新生成 debug.keystore 时，这个值会变，
     * 用户就会「装不上、只能先卸载」。所以必须真实读取，绝不能硬编码。
     * 任何一步失败都只写「未知」——诊断字段不该让整个导出失败。
     */
    private fun signatureSha256(ctx: Context): String {
        return try {
            val raw = certBytes(ctx)
            if (raw == null) "未知" else sha256Hex(raw)
        } catch (_: Throwable) {
            "未知"
        }
    }

    @Suppress("DEPRECATION")
    private fun certBytes(ctx: Context): ByteArray? {
        val pi = packageInfo(ctx) ?: return null
        val sig = if (Build.VERSION.SDK_INT >= 28) {
            val info = pi.signingInfo
            when {
                info == null -> null
                // 多签名（APK 签名方案轮转）时 signingCertificateHistory 会抛异常，
                // 必须先判 hasMultipleSigners 再决定走哪条路
                info.hasMultipleSigners() -> info.apkContentsSigners?.firstOrNull()
                else -> info.signingCertificateHistory?.firstOrNull()
                    ?: info.apkContentsSigners?.firstOrNull()
            }
        } else {
            // API 26 / 27 没有 SigningInfo，只能读已废弃的 signatures
            pi.signatures?.firstOrNull()
        }
        return sig?.toByteArray()
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(ctx: Context): PackageInfo? = try {
        val pm = ctx.packageManager
        if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(ctx.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            pm.getPackageInfo(ctx.packageName, 0)
        }
    } catch (_: Throwable) {
        null
    }

    @Suppress("DEPRECATION")
    private fun versionCodeOf(pi: PackageInfo?): Long =
        if (Build.VERSION.SDK_INT >= 28) {
            pi?.longVersionCode ?: 0L
        } else {
            (pi?.versionCode ?: 0).toLong()
        }

    private fun sha256Hex(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(data)
        val sb = StringBuilder(digest.size * 3)
        for (i in digest.indices) {
            if (i > 0) sb.append(':')
            val v = digest[i].toInt() and 0xFF
            sb.append(HEX[v ushr 4]).append(HEX[v and 0x0F])
        }
        return sb.toString()
    }

    // ================= 落盘 =================

    private fun writePrivate(ctx: Context, name: String, bytes: ByteArray): File? = try {
        // getExternalFilesDir 在存储挂载异常时返回 null，退回内部 filesDir 保证有产物
        val base = ctx.getExternalFilesDir(null) ?: ctx.filesDir
        val dir = File(base, DIR_NAME)
        if (!dir.exists()) dir.mkdirs()
        val f = File(dir, name)
        f.writeBytes(bytes)
        f
    } catch (_: Throwable) {
        null
    }

    /**
     * 公共下载目录副本（API 29+ 走 MediaStore，不需要任何权限）。
     * API 28 及以下要 WRITE_EXTERNAL_STORAGE 才能写公共目录，为一份副本去申请
     * 存储权限不划算（还会让用户警觉），直接跳过。
     */
    private fun writePublicCopy(ctx: Context, name: String, bytes: ByteArray) {
        if (Build.VERSION.SDK_INT < 29) return
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                Environment.DIRECTORY_DOWNLOADS + "/" + PUBLIC_FOLDER
            )
        }
        val uri = ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: return
        try {
            val os = ctx.contentResolver.openOutputStream(uri)
                ?: throw IllegalStateException("openOutputStream 返回 null")
            os.use { it.write(bytes) }
        } catch (e: Throwable) {
            // insert 成功但写失败会留下 0 字节的坏条目，清掉免得用户以为导出成功
            try {
                ctx.contentResolver.delete(uri, null, null)
            } catch (_: Throwable) {
            }
            throw e
        }
    }
}
