package com.yuanbao.qqbot

import android.app.Application
import android.content.Context

class App : Application() {
    companion object {
        @JvmStatic
        lateinit var ctx: Context
            private set
    }

    override fun onCreate() {
        super.onCreate()
        ctx = applicationContext
        CrashHandler.install(this)
    }
}
