package com.yuanbao.qqbot

import android.app.Application

class QQBotApp : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            CrashHandler.install(this)
        } catch (_: Throwable) {}
    }
}
