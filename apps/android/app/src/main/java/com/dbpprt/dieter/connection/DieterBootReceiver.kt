package com.dbpprt.dieter.connection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Restores an explicitly enabled always-connected session after reboot/update. */
class DieterBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        val pending = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val preferences = appContext.getSharedPreferences("dieter_connection", Context.MODE_PRIVATE)
                val mode = BackgroundSyncMode.resolve(
                    preferences.getString("background_sync_mode", null),
                )
                if (preferences.getBoolean("desired_connected", true) &&
                    mode.usesBackgroundService
                ) {
                    runCatching { DieterSyncService.start(appContext) }
                }
            } finally {
                pending.finish()
            }
        }
    }
}
