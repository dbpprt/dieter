package com.dbpprt.nauclio.connection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class NotificationDismissedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NauclioSyncService.ACTION_CHAT_NOTIFICATION_DISMISSED) return
        val cardId = intent.getStringExtra(NauclioSyncService.EXTRA_CARD_ID).orEmpty()
        val session = intent.getStringExtra(NauclioSyncService.EXTRA_SESSION).orEmpty()
        if (cardId.isBlank() || session.isBlank()) return
        context.getSharedPreferences(NauclioSyncService.NOTIFICATION_PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(NauclioSyncService.dismissedChatKey(cardId), session)
            .apply()
    }
}
