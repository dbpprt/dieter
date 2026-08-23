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
        val projectId = intent.getStringExtra(DieterSyncService.EXTRA_PROJECT_ID).orEmpty()
        val notificationId = intent.getIntExtra(DieterSyncService.EXTRA_NOTIFICATION_ID, 0)
        if (cardId.isBlank()) return
        val container = (context.applicationContext as DieterApplication).container
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                if (projectId.isNotBlank()) {
                    runCatching { container.connectionManager.ensureProjectRoute(projectId) }
                }
                val state = container.connectionManager.state.value
                val card = state.cards.firstOrNull { it.id == cardId }
                val doneLane = state.boards.firstOrNull { it.id == card?.boardId }
                    ?.lanesList?.lastOrNull()?.id ?: "done"
                container.repository.moveCard(cardId, doneLane)
                if (notificationId != 0) NotificationManagerCompat.from(context).cancel(notificationId)
            } catch (_: Exception) {
                // Leave the notification in place; the user can still open the card.
            } finally {
                pending.finish()
            }
        }
    }
}
