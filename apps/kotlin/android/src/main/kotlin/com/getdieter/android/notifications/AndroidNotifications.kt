package com.getdieter.android.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.getdieter.android.MainActivity
import com.getdieter.android.R
import com.getdieter.android.data.DieterCredentialStore
import com.getdieter.api.gateway.v1.PushProvider
import com.getdieter.core.notifications.AttentionNotificationSink
import com.getdieter.core.notifications.PushDelivery
import com.getdieter.core.notifications.PushDevice
import com.google.firebase.messaging.FirebaseMessaging
import okio.ByteString
import okio.ByteString.Companion.decodeBase64

/** Android OS surface; selection, suppression and account-bound taps live in core. */
class AndroidNotifications(private val context: Context) : AttentionNotificationSink {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val preferences = context.getSharedPreferences("dieter_push", Context.MODE_PRIVATE)
    private val keys = AndroidPushKeys(DieterCredentialStore(context))
    private val push = PushDelivery(keys::open)
    var openCard: ((String) -> Unit)? = null
    var refreshRegistration: (() -> Unit)? = null

    init {
        createChannel(context)
        DieterMessagingService.receiver = this
    }

    fun refreshToken() {
        if (!DieterNotificationApp.configured(context)) return
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token -> setToken(token) }
    }

    fun setToken(token: String) {
        preferences.edit().putString("token", token).apply()
        refreshRegistration?.invoke()
    }

    private fun allowed(): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            manager.getNotificationChannel(CHANNEL)?.importance !=
                NotificationManager.IMPORTANCE_NONE

    override fun device(accountKey: String): PushDevice? {
        val publicKey = keys.publicKey(accountKey) ?: return null
        main.post { push.bind(accountKey)?.let { openCard?.invoke(it) } }
        val token =
            if (allowed() && DieterNotificationApp.configured(context))
                preferences.getString("token", "").orEmpty()
            else ""
        return PushDevice(token, publicKey, false, PushProvider.FCM)
    }

    override fun registered(available: Boolean) {
        main.post { push.registered(available) }
    }

    override fun visible(cardId: String?) {
        main.post { push.visible(cardId) }
    }

    override fun post(cardId: String, title: String, text: String) {
        main.post {
            val account = push.accountKey ?: return@post
            if (!push.available)
                show(
                    LOCAL + cardId,
                    title,
                    text,
                    Intent(context, MainActivity::class.java)
                        .putExtra(CARD, cardId)
                        .putExtra(ACCOUNT, account),
                )
        }
    }

    private fun show(tag: String, title: String, text: String, intent: Intent, badge: Int = 0) {
        if (!allowed()) return
        intent.action = tag
        intent.flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        // Distinct PendingIntents without putting a plaintext task ID in a URI.
        val pending =
            PendingIntent.getActivity(
                context,
                tag.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val notification =
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setNumber(badge)
                .addExtras(
                    android.os.Bundle().apply {
                        intent.getStringExtra(SEALED)?.let { putString(SEALED, it) }
                    }
                )
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .build()
        try {
            manager.notify(tag, 0, notification)
        } catch (_: SecurityException) {
            /* Permission changed. */
        }
    }

    /** FCM shows notification+data itself in the background; this is its foreground callback. */
    fun receive(data: Map<String, String>) {
        main.post {
            val sealed = envelope(data[SEALED]) ?: return@post
            if (!push.present(sealed)) return@post
            show(
                REMOTE + sealed.base64(),
                "Task needs you",
                "Open Dieter to view the task requiring your attention.",
                Intent(context, MainActivity::class.java).putExtra(SEALED, sealed.base64()),
                data["dieter_badge"]?.toIntOrNull()?.coerceIn(0, 9999) ?: 0,
            )
        }
    }

    fun tap(intent: Intent) {
        envelope(intent.getStringExtra(SEALED))?.let {
            push.tap(it)?.let { id -> openCard?.invoke(id) }
        }
        val account = intent.getStringExtra(ACCOUNT)
        val cardId = intent.getStringExtra(CARD)
        if (account != null && cardId != null)
            push.tapLocal(account, cardId)?.let { openCard?.invoke(it) }
        intent.removeExtra(ACCOUNT)
        intent.removeExtra(SEALED)
        intent.removeExtra(CARD)
    }

    override fun reconcile(cardIds: List<String>, badge: Int) {
        main.post {
            val keep = cardIds.toSet()
            for (notification in manager.activeNotifications) {
                if (notification.notification.channelId != CHANNEL) continue
                val intentData =
                    notification.tag?.takeIf { it.startsWith(REMOTE) }?.removePrefix(REMOTE)
                        ?: notification.notification.extras.getString(SEALED)
                val local = notification.tag?.takeIf { it.startsWith(LOCAL) }?.removePrefix(LOCAL)
                val remote = envelope(intentData)?.let(push::cardId)
                if (
                    (local != null && local !in keep) ||
                        (remote != null && remote !in keep) ||
                        badge == 0
                )
                    manager.cancel(notification.tag, notification.id)
            }
        }
    }

    override fun reset() {
        main.post {
            push.reset()
            manager.activeNotifications
                .filter { it.notification.channelId == CHANNEL }
                .forEach { manager.cancel(it.tag, it.id) }
        }
    }

    fun close() {
        openCard = null
        refreshRegistration = null
        if (DieterMessagingService.receiver === this) DieterMessagingService.receiver = null
    }

    companion object {
        const val CHANNEL = "dieter.attention"
        const val SEALED = "dieter_sealed"
        const val CARD = "dieter.cardId"
        private const val ACCOUNT = "dieter.account"
        private const val LOCAL = "dieter.attention.local."
        private const val REMOTE = "dieter.attention.remote."

        fun createChannel(context: Context) {
            context
                .getSystemService(NotificationManager::class.java)
                .createNotificationChannel(
                    NotificationChannel(
                            CHANNEL,
                            "Tasks needing you",
                            NotificationManager.IMPORTANCE_DEFAULT,
                        )
                        .apply { setShowBadge(true) }
                )
        }

        fun clear(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.activeNotifications
                .filter { it.notification.channelId == CHANNEL }
                .forEach { manager.cancel(it.tag, it.id) }
        }

        private fun envelope(value: String?): ByteString? =
            value?.takeIf { it.length <= 2732 }?.decodeBase64()?.takeIf { it.size in 60..2048 }
    }
}
