package com.dbpprt.dieter.connection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import com.dbpprt.dieter.DieterApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Handles actionable notification buttons, e.g. marking a review card done from the shade. */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DieterSyncService.ACTION_MARK_CARD_DONE) return
        val cardId = intent.getStringExtra(DieterSyncService.EXTRA_CARD_ID).orEmpty()
        val tag = intent.getStringExtra(DieterSyncService.EXTRA_NOTIFICATION_TAG)
        if (cardId.isBlank()) return
        val core = (context.applicationContext as DieterApplication).container.core
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                if (core.onBoard { finish(cardId) } && tag != null) {
                    NotificationManagerCompat.from(context).cancel(tag, AndroidNotifications.CONTENT_ID)
                }
            } catch (_: Exception) {
                // Leave the notification in place; the user can still open the card.
            } finally {
                pending.finish()
            }
        }
    }
}
