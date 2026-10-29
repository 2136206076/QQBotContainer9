package com.yuanbao.qqbot

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.appcompat.app.AppCompatActivity

/** 内置网页：控制台 / noVNC 扫码 */
class WebActivity : AppCompatActivity() {

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        title = intent.getStringExtra("t") ?: "QQ 机器人"
        val url = intent.getStringExtra("u") ?: return finish()
        val wv = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.loadWithOverviewMode = true
            settings.useWideViewPort = true
            settings.cacheMode = WebSettings.LOAD_NO_CACHE
        }
        setContentView(wv)
        wv.loadUrl(url)
    }

    companion object {
        fun open(ctx: Context, title: String, url: String) {
            ctx.startActivity(Intent(ctx, WebActivity::class.java).putExtra("t", title).putExtra("u", url))
        }
    }
}
