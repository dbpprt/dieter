package com.dbpprt.nauclio.connection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restores an explicitly enabled always-connected session after reboot/update. */
class NauclioBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        val preferences = context.getSharedPreferences("nauclio_connection", Context.MODE_PRIVATE)
        if (!preferences.getBoolean("desired_connected", true) || !preferences.getBoolean("background_sync", true)) return
        runCatching { NauclioSyncService.start(context) }
    }
}
