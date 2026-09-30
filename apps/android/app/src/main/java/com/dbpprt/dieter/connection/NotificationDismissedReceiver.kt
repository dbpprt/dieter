package com.dbpprt.dieter.connection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.dbpprt.dieter.DieterApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class NotificationDismissedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DieterSyncService.ACTION_CHAT_NOTIFICATION_DISMISSED) return
        val cardId = intent.getStringExtra(DieterSyncService.EXTRA_CARD_ID).orEmpty()
        val session = intent.getStringExtra(DieterSyncService.EXTRA_SESSION).orEmpty()
        if (cardId.isBlank() || session.isBlank()) return
        val core = (context.applicationContext as DieterApplication).container.core
        val pending = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                core.dismissRunningNotification(cardId, session)
            } finally {
                pending.finish()
            }
        }
    }
}
