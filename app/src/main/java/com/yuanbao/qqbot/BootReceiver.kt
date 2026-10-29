package com.yuanbao.qqbot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.io.File

/** 开机/升级后自动拉起（前提是已经部署过） */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent?) {
        val act = intent?.action
        if (act != Intent.ACTION_BOOT_COMPLETED && act != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!File(Proot.rootfs(ctx), Cfg.DEPLOYED_MARK.trimStart('/')).exists()) return
        DeployService.go(ctx, DeployService.START)
    }
}
