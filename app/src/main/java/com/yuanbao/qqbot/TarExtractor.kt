package com.yuanbao.qqbot

import android.system.Os
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.zip.GZIPInputStream

/**
 * 最小 tar 解压器（够解 ubuntu-base）。
 * 为什么不直接调系统 tar：Android 的 toybox tar 版本参差，且硬链接在部分文件系统上会失败。
 * 这里把硬链接降级成"复制一份"，最稳。
 */
object TarExtractor {

    fun extractGz(gzFile: File, dest: File, onProgress: (Long) -> Unit): Int {
        var count = 0
        BufferedInputStream(gzFile.inputStream(), 1 shl 16).use { bis ->
            GZIPInputStream(bis, 1 shl 16).use { gis ->
                count = extract(gis, dest, onProgress)
            }
        }
        return count
    }

    private fun extract(`in`: InputStream, dest: File, onProgress: (Long) -> Unit): Int {
        dest.mkdirs()
        val buf = ByteArray(512)
        var count = 0
        var pendingLongName: String? = null
        while (true) {
            var read = 0
            while (read < 512) {
                val r = `in`.read(buf, read, 512 - read)
                if (r < 0) break
                read += r
            }
            if (read < 512) break
            if (buf.all { it == 0.toByte() }) {           // 结束标记（连续两个空块）
                `in`.read(buf, 0, 512)
                break
            }
            val name0 = str(buf, 0, 100)
            val size = octal(buf, 124, 12)
            val type = buf[156].toInt().toChar()
            val link = str(buf, 157, 100)
            val prefix = str(buf, 345, 155)
            val magic = str(buf, 257, 6)

            // GNU 长名 / pax：payload 里放真正的文件名
            if (type == 'L' || type == 'K') {
                pendingLongName = String(readExact(`in`, size)).trimEnd(0.toChar())
                skipPadding(`in`, size)
                continue
            }
            if (type == 'x' || type == 'g') {
                val payload = String(readExact(`in`, size))
                skipPadding(`in`, size)
                val m = Regex("(?:\\d+ )?path=([^\n]*)\n").find(payload)
                if (m != null) pendingLongName = m.groupValues[1]
                continue
            }

            val rawName = pendingLongName ?: if (magic.startsWith("ustar") && prefix.isNotEmpty())
                "$prefix/$name0" else name0
            pendingLongName = null
            val name = rawName.trim().trimStart('/')
            if (name.isEmpty() || name.contains("..")) { skipData(`in`, size); continue }

            val out = File(dest, name)
            val mode = octal(buf, 100, 8).toInt() and 511   // 0o777
            when (type) {
                '5' -> out.mkdirs()
                '2' -> { out.parentFile?.mkdirs(); symlink(link, out) }      // 符号链接
                '1' -> { out.parentFile?.mkdirs(); hardlink(File(dest, link.trimStart('/')), out) }
                '3', '4', '6' -> skipData(`in`, size)                        // 设备节点跳过
                else -> {
                    out.parentFile?.mkdirs()
                    FileOutputStream(out).use { fos ->
                        var remain = size
                        val chunk = ByteArray(1 shl 16)
                        while (remain > 0) {
                            val n = `in`.read(chunk, 0, minOf(remain, chunk.size.toLong()).toInt())
                            if (n <= 0) break
                            fos.write(chunk, 0, n)
                            remain -= n
                        }
                    }
                    skipPadding(`in`, size)
                    if (mode and 73 != 0) chmod(out, mode)   // 0o111: 可执行文件
                }
            }
            count++
            if (count % 200 == 0) onProgress(count.toLong())
        }
        onProgress(count.toLong())
        return count
    }

    /** 跳过 payload 后面补齐到 512 字节边界的填充 */
    private fun skipPadding(`in`: InputStream, size: Long) {
        val pad = (512 - (size % 512)) % 512
        if (pad > 0) skipBytes(`in`, pad)
    }

    /** 跳过整个条目数据块（含填充） */
    private fun skipData(`in`: InputStream, size: Long) {
        if (size > 0) skipBytes(`in`, size)
        skipPadding(`in`, size)
    }

    private fun readExact(`in`: InputStream, n: Long): ByteArray {
        val out = ByteArray(n.toInt())
        var off = 0
        while (off < out.size) {
            val r = `in`.read(out, off, out.size - off)
            if (r <= 0) break
            off += r
        }
        return if (off == out.size) out else out.copyOf(off)
    }

    private fun skipBytes(`in`: InputStream, n: Long) {
        var left = n
        val junk = ByteArray(1 shl 16)
        while (left > 0) {
            val r = `in`.read(junk, 0, minOf(left, junk.size.toLong()).toInt())
            if (r <= 0) break
            left -= r
        }
    }

    private fun symlink(target: String, out: File) {
        if (out.exists()) out.delete()
        try { Os.symlink(target, out.absolutePath) } catch (_: Exception) {}
    }

    private fun hardlink(src: File, out: File) {
        if (out.exists()) out.delete()
        try {
            Os.link(src.absolutePath, out.absolutePath)
        } catch (_: Exception) {
            try { src.copyTo(out) } catch (_: Exception) {}
        }
    }

    private fun chmod(f: File, mode: Int) {
        try { Os.chmod(f.absolutePath, mode) } catch (_: Exception) {}
    }

    private fun str(b: ByteArray, off: Int, len: Int): String {
        var end = off
        while (end < off + len && b[end] != 0.toByte()) end++
        return String(b, off, end - off)
    }

    private fun octal(b: ByteArray, off: Int, len: Int): Long {
        var v = 0L
        var started = false
        for (i in off until off + len) {
            val c = b[i].toInt().toChar()
            if (c in '0'..'7') { v = v * 8 + (c - '0'); started = true }
            else if (started || c == ' ' || c == 0.toChar()) continue
        }
        return v
    }
}
