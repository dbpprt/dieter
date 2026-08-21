package com.dbpprt.nauclio.connection

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.dbpprt.nauclio.NauclioApplication
import com.dbpprt.nauclio.MainActivity
import com.dbpprt.nauclio.R
import com.dbpprt.nauclio.v1.Card
import com.dbpprt.nauclio.v1.ConversationSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

class NauclioSyncService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var manager: NauclioConnectionManager
    private lateinit var notifications: NotificationManagerCompat
    private val transitions = NotificationTransitionTracker()
    private var collectionJob: Job? = null
    private var wakeLockJob: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var postedRunningChatIds: Set<String> = emptySet()
    private var postedReviewCardIds: Set<String> = emptySet()

    override fun onCreate() {
        super.onCreate()
        manager = (application as NauclioApplication).container.connectionManager
        notifications = NotificationManagerCompat.from(this)
        createChannels()
        startInForeground(connectionNotification(manager.state.value))
        startWakeLockRenewal()
        manager.onServiceStarted()
        collectionJob = serviceScope.launch {
            manager.state
                .combine((application as NauclioApplication).container.appPreferences.notificationBoardIds) { state, boardIds ->
                    state to boardIds
                }
                .collectLatest { (state, boardIds) -> render(state, boardIds) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT -> {
                manager.disconnect(stopService = false)
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_STOP_BACKGROUND -> {
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> manager.onServiceStarted()
        }
        return if (manager.state.value.desiredConnected && manager.state.value.backgroundSyncEnabled) START_STICKY else START_NOT_STICKY
    }

    override fun onDestroy() {
        collectionJob?.cancel()
        wakeLockJob?.cancel()
        releaseWakeLock()
        serviceScope.cancel()
        manager.onServiceStopped()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startInForeground(notification: Notification) {
        ServiceCompat.startForeground(
            this,
            CONNECTION_NOTIFICATION_ID,
            notification,
            if (android.os.Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING else 0,
        )
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        val lock = wakeLock ?: getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:global-sync")
            .also { it.setReferenceCounted(false); wakeLock = it }
        if (lock.isHeld) lock.release()
        lock.acquire(WAKE_LOCK_TIMEOUT_MS)
    }

    private fun startWakeLockRenewal() {
        acquireWakeLock()
        wakeLockJob?.cancel()
        wakeLockJob = serviceScope.launch {
            while (true) {
                kotlinx.coroutines.delay(WAKE_LOCK_RENEW_MS)
                if (manager.state.value.desiredConnected && manager.state.value.backgroundSyncEnabled) acquireWakeLock()
            }
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf(PowerManager.WakeLock::isHeld)?.release()
    }

    private fun render(state: NauclioConnectionState, notificationBoardIds: Set<String>) {
        if (!state.desiredConnected || !state.backgroundSyncEnabled) {
            releaseWakeLock()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        startInForeground(connectionNotification(state))
        val events = transitions.update(state.cards, state.chats, state.activeConversations, notificationBoardIds)
        if (canPostNotifications()) {
            renderRunningChats(state.chats, state.activeConversations)
            cancelDisabledBoardNotifications(state.cards, notificationBoardIds)
            events.forEach { postEvent(it, state.boards) }
        }
    }

    private fun cancelDisabledBoardNotifications(cards: List<Card>, notificationBoardIds: Set<String>) {
        val cardsById = cards.associateBy(Card::getId)
        val disabledCardIds = postedReviewCardIds.filterTo(mutableSetOf()) { cardId ->
            cardsById[cardId]?.boardId !in notificationBoardIds
        }
        disabledCardIds.forEach { notifications.cancel(reviewNotificationId(it)) }
        postedReviewCardIds -= disabledCardIds
    }

    private fun renderRunningChats(chats: List<Card>, conversations: Map<String, ConversationSnapshot>) {
        val activeIds = chats.filter { it.scope == "chat" && it.boardId.isBlank() && isActiveRuntime(it.runtime) }
            .mapTo(mutableSetOf(), Card::getId)
        (postedRunningChatIds - activeIds).forEach { notifications.cancel(runningChatNotificationId(it)) }
        postedRunningChatIds = activeIds
        val preferences = getSharedPreferences(NOTIFICATION_PREFERENCES, Context.MODE_PRIVATE)
        chats.filter { it.id in activeIds }.forEach { chat ->
            val session = chatSession(chat)
            if (preferences.getString(dismissedChatKey(chat.id), null) == session) return@forEach
            postNotification(
                runningChatNotificationId(chat.id),
                runningChatNotification(chat, conversations[chat.id], session),
            )
        }
    }

    private fun postEvent(event: NauclioNotificationEvent, boards: List<com.dbpprt.nauclio.v1.Board>) {
        when (event) {
            is NauclioNotificationEvent.ChatFinished -> {
                notifications.cancel(runningChatNotificationId(event.card.id))
                getSharedPreferences(NOTIFICATION_PREFERENCES, Context.MODE_PRIVATE)
                    .edit().remove(dismissedChatKey(event.card.id)).apply()
                postNotification(terminalNotificationId(event.card.id), terminalChatNotification(event))
            }
            is NauclioNotificationEvent.ReadyForReview -> {
                val boardName = boards.firstOrNull { it.id == event.card.boardId }?.name.orEmpty()
                postNotification(reviewNotificationId(event.card.id), reviewNotification(event.card, boardName))
                postedReviewCardIds += event.card.id
            }
        }
    }

    private fun connectionNotification(state: NauclioConnectionState): Notification {
        val connected = state.phase == ConnectionPhase.CONNECTED
        val endpoint = state.endpoint
        val activityPreview = modelActivityPreview(
            activeCardsById = (state.cards + state.chats)
                .filter { card -> isActiveRuntime(card.runtime) }
                .associateBy(Card::getId),
            conversations = state.activeConversations,
        )
        val activeSubagents = state.activeConversations.values.sumOf { snapshot ->
            snapshot.conversation.subagentsList.count { it.status == "running" || it.status == "pending" }
        }
        val reviews = state.cards.count { it.lane.equals("review", true) }
        val title = when (state.phase) {
            ConnectionPhase.CONNECTED -> "Connected to Nauclio"
            ConnectionPhase.SYNCING -> "Synchronizing Nauclio"
            ConnectionPhase.RECONNECTING -> "Reconnecting to Nauclio"
            ConnectionPhase.AUTH_REQUIRED -> "Sign in to Nauclio"
            ConnectionPhase.INCOMPATIBLE -> "Incompatible Nauclio server"
            ConnectionPhase.UNAVAILABLE -> "Nauclio is unavailable"
            else -> "Connecting to Nauclio"
        }
        val endpointText = endpoint?.let { "${it.label} · ${it.address}" } ?: "Trying configured addresses"
        val summary = if (connected) "$endpointText · live updates in background" else state.error ?: endpointText
        val stats = "${state.boards.size} boards · $reviews review · $activeSubagents subagents"
        val builder = Notification.Builder(this, CONNECTION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(summary)
            .setSubText(
                when {
                    connected && activityPreview.totalCount > 0 -> activeNowLabel(activityPreview.totalCount)
                    connected -> stats
                    else -> null
                },
            )
            .setColor(NOTIFICATION_ACCENT)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openIntent(showConnection = true))
            .addAction(Notification.Action.Builder(null, "Disconnect", serviceIntent(ACTION_DISCONNECT, 11)).build())
            .addAction(Notification.Action.Builder(null, "Open", openIntent(showConnection = true)).build())
        if (connected && activityPreview.totalCount > 0) {
            builder.setStyle(connectionActivityStyle(activityPreview, stats))
        } else {
            builder.setStyle(Notification.BigTextStyle().bigText("$summary\n$stats"))
        }
        return builder.build()
    }

    private fun runningChatNotification(chat: Card, snapshot: ConversationSnapshot?, session: String): Notification {
        val preview = modelActivityPreview(
            activeCardsById = mapOf(chat.id to chat),
            conversations = snapshot?.let { mapOf(chat.id to it) }.orEmpty(),
        )
        val activity = preview.rows.firstOrNull()?.detail ?: "Working on your request"
        return Notification.Builder(this, RUNNING_CHAT_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(chat.title.ifBlank { "Running chat" })
            .setContentText(activity)
            .setSubText(activeNowLabel(preview.totalCount))
            .setStyle(runningChatActivityStyle(chat, preview))
            .setColor(NOTIFICATION_ACCENT)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setProgress(0, 0, true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setAutoCancel(false)
            .setOngoing(false)
            .setContentIntent(openIntent(cardId = chat.id))
            .setDeleteIntent(dismissIntent(chat, session))
            .build()
    }

    private fun connectionActivityStyle(preview: ModelActivityPreview, stats: String): Notification.InboxStyle =
        Notification.InboxStyle()
            .setBigContentTitle("Live model activity")
            .also { style ->
                preview.rows.forEach { row ->
                    val modelLabel = if (row.modelLabel == "Main model") "Main" else row.modelLabel
                    style.addLine(activityLine(row.cardTitle, "$modelLabel · ${row.detail}"))
                }
            }
            .setSummaryText(activitySummary(preview, stats))

    private fun runningChatActivityStyle(chat: Card, preview: ModelActivityPreview): Notification.InboxStyle =
        Notification.InboxStyle()
            .setBigContentTitle(chat.title.ifBlank { "Live activity" })
            .also { style ->
                preview.rows.forEach { row -> style.addLine(activityLine(row.modelLabel, row.detail)) }
            }
            .setSummaryText(activitySummary(preview, "Tap to open conversation"))

    private fun activityLine(label: String, detail: String): CharSequence = SpannableStringBuilder()
        .append("●  ", ForegroundColorSpan(NOTIFICATION_ACCENT), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        .append(label, StyleSpan(Typeface.BOLD), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        .append("  ·  ")
        .append(detail)

    private fun activitySummary(preview: ModelActivityPreview, trailingText: String): String =
        if (preview.overflowCount > 0) "+${preview.overflowCount} more active · $trailingText" else trailingText

    private fun activeNowLabel(count: Int): String = "$count ${if (count == 1) "model" else "models"} active now"

    private fun terminalChatNotification(event: NauclioNotificationEvent.ChatFinished): Notification {
        val runtime = event.card.runtime.lowercase()
        val title = when {
            event.subagentCount > 0 -> "Subagents finished · ${event.completedSubagentCount} of ${event.subagentCount}"
            runtime == "failed" -> "Chat failed"
            runtime in setOf("interrupted", "cancelled") -> "Chat stopped"
            runtime == "waiting_for_user" -> "Chat needs you"
            else -> "Chat finished"
        }
        return Notification.Builder(this, AGENT_RESULTS_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(event.card.title.ifBlank { "Standalone chat" })
            .setSubText("Nauclio")
            .setCategory(Notification.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setContentIntent(openIntent(cardId = event.card.id))
            .build()
    }

    private fun reviewNotification(card: Card, boardName: String): Notification = Notification.Builder(this, AGENT_RESULTS_CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_notification)
        .setContentTitle("Ready for review")
        .setContentText(card.title.ifBlank { "Nauclio conversation" })
        .setSubText(boardName.ifBlank { "Board" })
        .setCategory(Notification.CATEGORY_STATUS)
        .setAutoCancel(true)
        .setContentIntent(openIntent(cardId = card.id))
        .build()

    private fun openIntent(cardId: String = "", showConnection: Boolean = false): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_CARD_ID, cardId)
            .putExtra(EXTRA_SHOW_CONNECTION, showConnection)
        return PendingIntent.getActivity(
            this,
            ((cardId.hashCode() * 31 + if (showConnection) 1 else 0) and 0x7fffffff),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun serviceIntent(action: String, requestCode: Int): PendingIntent = PendingIntent.getService(
        this,
        requestCode,
        Intent(this, NauclioSyncService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun dismissIntent(chat: Card, session: String): PendingIntent = PendingIntent.getBroadcast(
        this,
        runningChatNotificationId(chat.id),
        Intent(this, NotificationDismissedReceiver::class.java)
            .setAction(ACTION_CHAT_NOTIFICATION_DISMISSED)
            .putExtra(EXTRA_CARD_ID, chat.id)
            .putExtra(EXTRA_SESSION, session),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun createChannels() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CONNECTION_CHANNEL_ID, "Nauclio connection", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Permanent status while Nauclio stays connected"
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(RUNNING_CHAT_CHANNEL_ID, "Running chats", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Silent progress while standalone chats are running"
                setSound(null, null)
                enableVibration(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(AGENT_RESULTS_CHANNEL_ID, "Agent results", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Completion, failure, stopped, needs-you, and review updates"
            },
        )
    }

    private fun canPostNotifications(): Boolean =
        Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    private fun postNotification(id: Int, notification: Notification) {
        if (!canPostNotifications()) return
        try {
            notifications.notify(id, notification)
        } catch (_: SecurityException) {
            // Permission can be revoked between the check and notification.
        }
    }

    companion object {
        const val ACTION_DISCONNECT = "com.dbpprt.nauclio.action.DISCONNECT"
        const val ACTION_STOP_BACKGROUND = "com.dbpprt.nauclio.action.STOP_BACKGROUND"
        const val ACTION_CHAT_NOTIFICATION_DISMISSED = "com.dbpprt.nauclio.action.CHAT_NOTIFICATION_DISMISSED"
        const val EXTRA_CARD_ID = "card_id"
        const val EXTRA_SHOW_CONNECTION = "show_connection"
        const val EXTRA_SESSION = "session"
        const val NOTIFICATION_PREFERENCES = "nauclio_notification_state"

        private const val CONNECTION_CHANNEL_ID = "nauclio_connection"
        private const val WAKE_LOCK_TIMEOUT_MS = 15 * 60 * 1_000L
        private const val WAKE_LOCK_RENEW_MS = 10 * 60 * 1_000L
        private val NOTIFICATION_ACCENT = Color.rgb(101, 84, 232)
        const val RUNNING_CHAT_CHANNEL_ID = "nauclio_agent_running"
        const val AGENT_RESULTS_CHANNEL_ID = "nauclio_agent_activity"
        const val CONNECTION_NOTIFICATION_ID = 1001

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, NauclioSyncService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, NauclioSyncService::class.java))
        }

        fun dismissedChatKey(cardId: String): String = "dismissed_chat_$cardId"

        private fun chatSession(card: Card): String = card.runtimeUpdatedAt.ifBlank { card.updatedAt.ifBlank { card.id } }
        private fun runningChatNotificationId(cardId: String): Int = 20_000 + (cardId.hashCode() and 0x3fff)
        private fun terminalNotificationId(cardId: String): Int = 40_000 + (cardId.hashCode() and 0x3fff)
        private fun reviewNotificationId(cardId: String): Int = 60_000 + (cardId.hashCode() and 0x3fff)
    }
}
