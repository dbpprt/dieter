package com.dbpprt.dieter.connection

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.R
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

class DieterSyncService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var manager: DieterConnectionManager
    private lateinit var notifications: NotificationManagerCompat
    private val transitions = NotificationTransitionTracker()
    private var collectionJob: Job? = null
    private var wakeLockJob: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var postedRunningChatIds: Set<String> = emptySet()
    private var postedReviewCardIds: Set<String> = emptySet()
    private val paletteTokens get() = AppPreferences.selectedPalette(this).tokens
    private val notificationAccent get() = paletteTokens.shellStartInt
    private val reviewAccent get() = Color.rgb(226, 190, 106)

    override fun onCreate() {
        super.onCreate()
        manager = (application as DieterApplication).container.connectionManager
        notifications = NotificationManagerCompat.from(this)
        createChannels()
        startInForeground(connectionNotification(manager.state.value))
        startWakeLockRenewal()
        manager.onServiceStarted()
        collectionJob = serviceScope.launch {
            manager.state
                .combine((application as DieterApplication).container.appPreferences.notificationBoardIds) { state, boardIds ->
                    state to boardIds
                }
                .combine((application as DieterApplication).container.appPreferences.palette) { stateAndBoards, _ ->
                    stateAndBoards
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

    private fun render(state: DieterConnectionState, notificationBoardIds: Set<String>) {
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

    private fun postEvent(event: DieterNotificationEvent, boards: List<com.dbpprt.dieter.v1.Board>) {
        when (event) {
            is DieterNotificationEvent.ChatFinished -> {
                notifications.cancel(runningChatNotificationId(event.card.id))
                getSharedPreferences(NOTIFICATION_PREFERENCES, Context.MODE_PRIVATE)
                    .edit().remove(dismissedChatKey(event.card.id)).apply()
                postNotification(terminalNotificationId(event.card.id), terminalChatNotification(event))
            }
            is DieterNotificationEvent.ReadyForReview -> {
                val boardName = boards.firstOrNull { it.id == event.card.boardId }?.name.orEmpty()
                postNotification(reviewNotificationId(event.card.id), reviewNotification(event.card, boardName))
                postedReviewCardIds += event.card.id
            }
        }
        postNotification(RESULTS_SUMMARY_NOTIFICATION_ID, resultsGroupSummary())
    }

    private fun connectionNotification(state: DieterConnectionState): Notification {
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
        val hostname = state.projectHosts.values.firstOrNull { host ->
            host.online && (endpoint == null || host.endpointId == endpoint.id)
        }?.hostname ?: state.projectHosts.values.firstOrNull { it.online }?.hostname
        val title = when (state.phase) {
            ConnectionPhase.CONNECTED -> "Connected to ${hostname ?: endpoint?.label ?: "Dieter"}"
            ConnectionPhase.SYNCING -> "Synchronizing Dieter"
            ConnectionPhase.RECONNECTING -> "Reconnecting to Dieter"
            ConnectionPhase.AUTH_REQUIRED -> "Sign in to Dieter"
            ConnectionPhase.INCOMPATIBLE -> "Incompatible Dieter server"
            ConnectionPhase.UNAVAILABLE -> "Dieter is unavailable"
            else -> "Connecting to Dieter"
        }
        val endpointText = endpoint?.let { "${it.label} · ${it.address.substringBefore(':')}" }
            ?: "Trying configured addresses"
        val summary = if (connected) "$endpointText · polling in background" else state.error ?: endpointText
        val builder = Notification.Builder(this, CONNECTION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(summary)
            .setSubText(
                when {
                    connected && activityPreview.totalCount > 0 -> activeNowLabel(activityPreview.totalCount)
                    connected -> "Ongoing"
                    else -> null
                },
            )
            .setLargeIcon(connectionBadge(connected))
            .setColor(notificationAccent)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openIntent(showConnection = true))
            .addAction(Notification.Action.Builder(null, "Disconnect", serviceIntent(ACTION_DISCONNECT, 11)).build())
            .addAction(Notification.Action.Builder(null, "Open", openIntent(showConnection = true)).build())
        if (Build.VERSION.SDK_INT >= 36 && connected) {
            // Surface live agent work as an Android 16 promoted Live Update chip.
            if (Build.VERSION.SDK_INT_FULL >= Build.VERSION_CODES_FULL.BAKLAVA_1) {
                builder.setRequestPromotedOngoing(true)
            }
            if (activityPreview.totalCount > 0) {
                builder.setShortCriticalText("${activityPreview.totalCount} active")
            }
        }
        builder.setStyle(Notification.DecoratedCustomViewStyle())
        builder.setCustomBigContentView(
            connectionExpandedView(
                title = title,
                summary = summary,
                boards = state.boards.size,
                reviews = reviews,
                subagents = activeSubagents,
                preview = if (connected) activityPreview else null,
            ),
        )
        return builder.build()
    }

    /** Expanded shade body matching the design reference: stat pills plus live activity rows. */
    private fun connectionExpandedView(
        title: String,
        summary: String,
        boards: Int,
        reviews: Int,
        subagents: Int,
        preview: ModelActivityPreview?,
    ): RemoteViews {
        val view = RemoteViews(packageName, R.layout.notification_connection_expanded)
        view.setTextViewText(R.id.notification_title, title)
        view.setTextViewText(R.id.notification_text, summary)
        view.setTextViewText(R.id.notification_chip_boards, "$boards ${if (boards == 1) "board" else "boards"}")
        val darkMode = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val neutralBackground = if (darkMode) paletteTokens.darkRaisedInt else paletteTokens.paneStartInt
        val neutralText = if (darkMode) paletteTokens.paneStartInt else paletteTokens.darkRaisedInt
        view.setTextColor(R.id.notification_chip_boards, neutralText)
        view.setTextColor(R.id.notification_chip_subagents, neutralText)
        if (Build.VERSION.SDK_INT >= 31) {
            val tint = ColorStateList.valueOf(neutralBackground)
            view.setColorStateList(R.id.notification_chip_boards, "setBackgroundTintList", tint)
            view.setColorStateList(R.id.notification_chip_subagents, "setBackgroundTintList", tint)
        }
        if (reviews > 0) {
            view.setTextViewText(R.id.notification_chip_reviews, "$reviews ${if (reviews == 1) "review" else "reviews"}")
            view.setViewVisibility(R.id.notification_chip_reviews, View.VISIBLE)
        }
        if (subagents > 0) {
            view.setTextViewText(R.id.notification_chip_subagents, "• $subagents ${if (subagents == 1) "subagent" else "subagents"}")
            view.setViewVisibility(R.id.notification_chip_subagents, View.VISIBLE)
        }
        val rowIds = listOf(R.id.notification_activity_1, R.id.notification_activity_2, R.id.notification_activity_3)
        val rows = preview?.rows.orEmpty()
        if (rows.isNotEmpty()) {
            view.setViewVisibility(R.id.notification_activity, View.VISIBLE)
            rows.zip(rowIds).forEach { (row, id) ->
                val modelLabel = if (row.modelLabel == "Main model") "Main" else row.modelLabel
                view.setTextViewText(id, activityLine(row.cardTitle, "$modelLabel · ${row.detail}"))
                view.setViewVisibility(id, View.VISIBLE)
            }
            val overflow = rows.size - minOf(rows.size, rowIds.size) + (preview?.overflowCount ?: 0)
            if (overflow > 0) {
                view.setTextViewText(R.id.notification_activity_more, "+$overflow more active")
                view.setViewVisibility(R.id.notification_activity_more, View.VISIBLE)
            }
        }
        return view
    }

    /** Rounded status tile shown as the large icon: green wifi when connected, muted when not. */
    private fun connectionBadge(connected: Boolean): android.graphics.drawable.Icon {
        val size = 192
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val tile = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (connected) paletteTokens.eyesTintInt else paletteTokens.darkRaisedInt
        }
        canvas.drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), 52f, 52f, tile)
        val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (connected) paletteTokens.eyesInt else paletteTokens.mutedInt
            style = Paint.Style.STROKE
            strokeWidth = 14f
            strokeCap = Paint.Cap.ROUND
        }
        val cx = size / 2f
        val cy = size * 0.66f
        listOf(30f, 54f).forEach { radius ->
            canvas.drawArc(RectF(cx - radius, cy - radius, cx + radius, cy + radius), 215f, 110f, false, glyph)
        }
        canvas.drawCircle(cx, cy - 2f, 10f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = glyph.color })
        return android.graphics.drawable.Icon.createWithBitmap(bitmap)
    }

    private fun runningChatNotification(chat: Card, snapshot: ConversationSnapshot?, session: String): Notification {
        val preview = modelActivityPreview(
            activeCardsById = mapOf(chat.id to chat),
            conversations = snapshot?.let { mapOf(chat.id to it) }.orEmpty(),
        )
        val activity = preview.rows.firstOrNull()?.detail ?: "Working on your request"
        val builder = Notification.Builder(this, RUNNING_CHAT_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(chat.title.ifBlank { "Running chat" })
            .setContentText(activity)
            .setSubText(activeNowLabel(preview.totalCount))
            .setColor(notificationAccent)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setAutoCancel(false)
            .setOngoing(false)
            .setContentIntent(openIntent(cardId = chat.id))
            .setDeleteIntent(dismissIntent(chat, session))
        if (Build.VERSION.SDK_INT >= 36 && preview.rows.size <= 1) {
            // Android 16 ProgressStyle renders the fancy segmented live progress bar.
            builder.setStyle(
                Notification.ProgressStyle()
                    .setProgressIndeterminate(true)
                    .setStyledByProgress(false),
            )
        } else {
            builder.setProgress(0, 0, true)
            builder.setStyle(runningChatActivityStyle(chat, preview))
        }
        return builder.build()
    }

    private fun runningChatActivityStyle(chat: Card, preview: ModelActivityPreview): Notification.InboxStyle =
        Notification.InboxStyle()
            .setBigContentTitle(chat.title.ifBlank { "Live activity" })
            .also { style ->
                preview.rows.forEach { row -> style.addLine(activityLine(row.modelLabel, row.detail)) }
            }
            .setSummaryText(activitySummary(preview, "Tap to open conversation"))

    private fun activityLine(label: String, detail: String): CharSequence = SpannableStringBuilder()
        .append("●  ", ForegroundColorSpan(notificationAccent), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        .append(label, StyleSpan(Typeface.BOLD), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        .append("  ·  ")
        .append(detail)

    private fun activitySummary(preview: ModelActivityPreview, trailingText: CharSequence): CharSequence =
        if (preview.overflowCount > 0) {
            SpannableStringBuilder("+${preview.overflowCount} more active · ").append(trailingText)
        } else {
            trailingText
        }

    private fun activeNowLabel(count: Int): String = "$count ${if (count == 1) "model" else "models"} active now"

    private fun terminalChatNotification(event: DieterNotificationEvent.ChatFinished): Notification {
        val runtime = event.card.runtime.lowercase()
        val title = when {
            event.subagentCount > 0 -> "Subagents finished · ${event.completedSubagentCount} of ${event.subagentCount}"
            runtime == "failed" -> "Chat failed"
            runtime in setOf("interrupted", "cancelled") -> "Chat stopped"
            runtime == "waiting_for_user" -> "Chat needs you"
            else -> "Chat finished"
        }
        val chatTitle = event.card.title.ifBlank { "Standalone chat" }
        val builder = Notification.Builder(this, AGENT_RESULTS_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(chatTitle)
            .setColor(notificationAccent)
            .setCategory(Notification.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setGroup(RESULTS_GROUP)
            .setContentIntent(openIntent(cardId = event.card.id))
        if (event.resultPreview.isNotBlank()) {
            // Show the agent's closing words so the outcome is readable from the shade.
            val expanded = SpannableStringBuilder()
                .append(chatTitle, StyleSpan(Typeface.BOLD), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                .append("\n")
                .append(event.resultPreview)
            builder.setStyle(Notification.BigTextStyle().bigText(expanded))
        }
        return builder.build()
    }

    private fun reviewNotification(card: Card, boardName: String): Notification {
        val cardTitle = card.title.ifBlank { "Dieter conversation" }
        val builder = Notification.Builder(this, AGENT_RESULTS_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Ready for review")
            .setContentText("$cardTitle · ${boardName.ifBlank { "Board" }}")
            .setColor(reviewAccent)
            .setCategory(Notification.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setGroup(RESULTS_GROUP)
            .setContentIntent(openIntent(cardId = card.id))
            .addAction(
                Notification.Action.Builder(null, "Mark done", markDoneIntent(card)).build(),
            )
            .addAction(Notification.Action.Builder(null, "Open", openIntent(cardId = card.id)).build())
        val summary = card.summary.trim()
        if (summary.isNotBlank()) {
            val expanded = SpannableStringBuilder()
                .append(cardTitle, StyleSpan(Typeface.BOLD), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                .append(" · ").append(boardName.ifBlank { "Board" })
                .append("\n")
                .append(summary)
            builder.setStyle(Notification.BigTextStyle().bigText(expanded))
        }
        return builder.build()
    }

    /** Collapses agent results into one tidy stack in the shade. */
    private fun resultsGroupSummary(): Notification = Notification.Builder(this, AGENT_RESULTS_CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_notification)
        .setColor(notificationAccent)
        .setCategory(Notification.CATEGORY_STATUS)
        .setGroup(RESULTS_GROUP)
        .setGroupSummary(true)
        .setAutoCancel(true)
        .setContentIntent(openIntent())
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
        Intent(this, DieterSyncService::class.java).setAction(action),
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

    private fun markDoneIntent(card: Card): PendingIntent = PendingIntent.getBroadcast(
        this,
        reviewNotificationId(card.id),
        Intent(this, NotificationActionReceiver::class.java)
            .setAction(ACTION_MARK_CARD_DONE)
            .putExtra(EXTRA_CARD_ID, card.id)
            .putExtra(EXTRA_PROJECT_ID, card.projectId)
            .putExtra(EXTRA_NOTIFICATION_ID, reviewNotificationId(card.id)),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun createChannels() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CONNECTION_CHANNEL_ID, "Dieter connection", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Permanent status while Dieter stays connected"
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
        const val ACTION_DISCONNECT = "com.dbpprt.dieter.action.DISCONNECT"
        const val ACTION_STOP_BACKGROUND = "com.dbpprt.dieter.action.STOP_BACKGROUND"
        const val ACTION_CHAT_NOTIFICATION_DISMISSED = "com.dbpprt.dieter.action.CHAT_NOTIFICATION_DISMISSED"
        const val ACTION_MARK_CARD_DONE = "com.dbpprt.dieter.action.MARK_CARD_DONE"
        const val EXTRA_CARD_ID = "card_id"
        const val EXTRA_PROJECT_ID = "project_id"
        const val EXTRA_NOTIFICATION_ID = "notification_id"
        const val EXTRA_SHOW_CONNECTION = "show_connection"
        const val EXTRA_SESSION = "session"
        const val NOTIFICATION_PREFERENCES = "dieter_notification_state"

        private const val CONNECTION_CHANNEL_ID = "dieter_connection"
        private const val WAKE_LOCK_TIMEOUT_MS = 15 * 60 * 1_000L
        private const val WAKE_LOCK_RENEW_MS = 10 * 60 * 1_000L
        private const val RESULTS_GROUP = "dieter_agent_results"
        private const val RESULTS_SUMMARY_NOTIFICATION_ID = 1002
        const val RUNNING_CHAT_CHANNEL_ID = "dieter_agent_running"
        const val AGENT_RESULTS_CHANNEL_ID = "dieter_agent_activity"
        const val CONNECTION_NOTIFICATION_ID = 1001

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, DieterSyncService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DieterSyncService::class.java))
        }

        fun dismissedChatKey(cardId: String): String = "dismissed_chat_$cardId"

        private fun chatSession(card: Card): String = card.runtimeUpdatedAt.ifBlank { card.updatedAt.ifBlank { card.id } }
        private fun runningChatNotificationId(cardId: String): Int = 20_000 + (cardId.hashCode() and 0x3fff)
        private fun terminalNotificationId(cardId: String): Int = 40_000 + (cardId.hashCode() and 0x3fff)
        private fun reviewNotificationId(cardId: String): Int = 60_000 + (cardId.hashCode() and 0x3fff)
    }
}
