package com.dbpprt.dieter.connection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class NotificationDismissedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DieterSyncService.ACTION_CHAT_NOTIFICATION_DISMISSED) return
        val cardId = intent.getStringExtra(DieterSyncService.EXTRA_CARD_ID).orEmpty()
        val session = intent.getStringExtra(DieterSyncService.EXTRA_SESSION).orEmpty()
        if (cardId.isBlank() || session.isBlank()) return
        context.getSharedPreferences(DieterSyncService.NOTIFICATION_PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(DieterSyncService.dismissedChatKey(cardId), session)
            .apply()
    }
}
