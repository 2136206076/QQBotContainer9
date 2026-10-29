package com.yuanbao.qqbot

import android.os.Handler
import android.os.Looper

/** 极简日志总线：后台线程写，主线程收。 */
object LogBus {
    private val main = Handler(Looper.getMainLooper())
    private val buf = StringBuilder()
    private val listeners = ArrayList<(String) -> Unit>()
    private var lastLine = ""

    fun log(line: String) {
        if (line == lastLine) return   // 去重，避免进度刷屏
        lastLine = line
        buf.append(line).append('\n')
        if (buf.length > 200_000) buf.delete(0, 100_000)
        main.post { listeners.forEach { it(line) } }
    }

    fun text(): String = buf.toString()

    fun listen(l: (String) -> Unit) {
        main.post { listeners.add(l) }
    }

    fun clear() { buf.setLength(0); lastLine = "" }
}

object Cfg {
    const val ROOTFS = "rootfs"                 // filesDir/rootfs
    const val STACK = "/opt/qqstack"            // 容器内的部署栈
    const val BOOTSTRAP_MARK = "/opt/qqstack/.bootstrapped"
    const val DEPLOYED_MARK = "/opt/qqstack/.deployed"

    // Ubuntu Base 24.04 arm64（官方 28MB）。想换源就改这里/或改 App 里的 URL
    // Ubuntu Base 24.04 arm64（官方 28MB）。按顺序试，哪个通下哪个；
    // 将来小版本号变了，改这里就行（目录：https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/）
    val ROOTFS_URLS = listOf(
        "https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/ubuntu-base-24.04.4-base-arm64.tar.gz",
        "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/noble/release/ubuntu-base-24.04.4-base-arm64.tar.gz",
        "https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/ubuntu-base-24.04.3-base-arm64.tar.gz"
    )

    // apt 源。国内默认走清华；不通时 proot-bootstrap.sh 会自动换回官方
    const val APT_SOURCE = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu"
    const val APT_SOURCE_OFFICIAL = "http://archive.ubuntu.com/ubuntu"

    const val AGENT_GIT = "https://github.com/K0nd1us/QQ-agent.git"
    const val SNOWLUMA_URL =
        "https://github.com/SnowLuma/SnowLuma/releases/download/v2.1.1/SnowLuma-v2.1.1-linux-arm64.tar.gz"

    const val AGENT_PORT = 3210
    const val NOVNC_PORT = 6081
    const val SLWEBUI_PORT = 5099
}
