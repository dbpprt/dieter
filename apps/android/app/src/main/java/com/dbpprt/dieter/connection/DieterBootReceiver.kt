package com.dbpprt.dieter.connection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.dbpprt.dieter.core.admin.BackgroundPolicy
import com.dbpprt.dieter.sharedcore.SharedCore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Restores an explicitly enabled always-connected session after reboot or update. */
class DieterBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        val pending = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            try {
                // Read before the core starts: the policy's keys live in the core's device settings.
                if (BackgroundPolicy.shouldAutostart(SharedCore.settings(appContext))) {
                    runCatching { DieterSyncService.start(appContext) }
                }
            } finally {
                pending.finish()
            }
        }
    }
}
