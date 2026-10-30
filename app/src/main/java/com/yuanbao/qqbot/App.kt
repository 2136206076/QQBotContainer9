package com.yuanbao.qqbot

import android.os.Handler
import android.os.Looper

/** 极简日志总线：后台线程写，主线程收。 */
object LogBus {
    private val main = Handler(Looper.getMainLooper())
    private val buf = StringBuilder()
    private val listeners = ArrayList<(String) -> Unit>()
    private val lock = Any()
    private var lastLine = ""

    fun log(line: String) {
        val snapshot: List<(String) -> Unit>
        synchronized(lock) {
            if (line == lastLine) return
            lastLine = line
            buf.append(line).append('\n')
            if (buf.length > 200_000) buf.delete(0, 100_000)
            snapshot = listeners.toList()
        }
        main.post {
            snapshot.forEach { l ->
                try { l(line) } catch (_: Throwable) {}
            }
        }
    }

    fun text(): String = synchronized(lock) { buf.toString() }

    fun listen(l: (String) -> Unit) {
        synchronized(lock) { listeners.add(l) }
    }

    fun unlisten(l: (String) -> Unit) {
        synchronized(lock) { listeners.remove(l) }
    }

    fun clear() {
        synchronized(lock) {
            buf.setLength(0)
            lastLine = ""
        }
    }
}

object Cfg {
    const val ROOTFS = "rootfs"
    const val STACK = "/opt/qqstack"
    const val BOOTSTRAP_MARK = "/opt/qqstack/.bootstrapped"
    const val DEPLOYED_MARK = "/opt/qqstack/.deployed"

    val ROOTFS_URLS = listOf(
        "https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/ubuntu-base-24.04.4-base-arm64.tar.gz",
        "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/noble/release/ubuntu-base-24.04.4-base-arm64.tar.gz",
        "https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/ubuntu-base-24.04.3-base-arm64.tar.gz"
    )

    const val APT_SOURCE = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
    const val APT_SOURCE_OFFICIAL = "http://ports.ubuntu.com/ubuntu-ports"

    const val AGENT_GIT = "https://github.com/K0nd1us/QQ-agent.git"
    const val SNOWLUMA_URL =
        "https://github.com/SnowLuma/SnowLuma/releases/download/v2.1.1/SnowLuma-v2.1.1-linux-arm64.tar.gz"

    const val AGENT_PORT = 3210
    const val NOVNC_PORT = 6081
    const val SLWEBUI_PORT = 5099

    const val QQ_DEB_NAME = "QQ_3.2.32_260812_arm64_01.deb"
    const val QQ_RELEASE_TAG = "qq-packages-20260813-1d08f1d4"
    val QQ_URLS = listOf(
        "https://gh-proxy.com/https://github.com/Rodert/qq-versions/releases/download/$QQ_RELEASE_TAG/$QQ_DEB_NAME",
        "https://ghproxy.net/https://github.com/Rodert/qq-versions/releases/download/$QQ_RELEASE_TAG/$QQ_DEB_NAME",
        "https://github.com/Rodert/qq-versions/releases/download/$QQ_RELEASE_TAG/$QQ_DEB_NAME"
    )
}
