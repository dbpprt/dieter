package com.dbpprt.dieter.connection

import android.annotation.SuppressLint
import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.R
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.core.admin.BackgroundPolicy
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.notifications.BackgroundStatus
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.notifications.NotificationStyle
import com.dbpprt.dieter.settings.DieterPalette
import com.dbpprt.dieter.sharedcore.ConnectionPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Keeps the shared core connected while the app is in the background. The
 * core decides when to run ([BackgroundPolicy]); this service holds the wake
 * lock, runs periodic windows, and shows the connection notification.
 */
class DieterSyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var core: CoreRuntime
    private lateinit var policy: ConnectionPolicy
    private var policyJob: Job? = null
    private var renderJob: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var palette = DieterPalette.DEFAULT
    private var lastRendered: Any? = null
    private var cachedBadge: Pair<Pair<Boolean, String>, android.graphics.drawable.Icon>? = null

    override fun onCreate() {
        super.onCreate()
        val container = (application as DieterApplication).container
        core = container.core
        policy = container.policy
        palette = container.appPreferences.palette.value
        // Foreground services must publish immediately; the full notification follows.
        startInForeground(bootstrapNotification())
        policy.setServiceActive(true)
        policyJob = scope.launch {
            combine(policy.desired, policy.mode) { desired, mode -> desired to mode }.collectLatest { (desired, mode) ->
                if (!desired || !mode.usesBackgroundService) {
                    policy.setPeriodicWindow(false)
                    releaseWakeLock()
                    return@collectLatest
                }
                when (mode) {
                    BackgroundMode.LIVE -> {
                        policy.setPeriodicWindow(false)
                        whileWakeLockHeld { awaitCancellation() }
                    }
                    BackgroundMode.PERIODIC -> runPeriodicPolicy()
                    BackgroundMode.APP_ONLY -> Unit
                }
            }
        }
        renderJob = scope.launch {
            combine(core.connection.state, core.workspace.state, core.outbox.view, policy.mode, container.appPreferences.palette) { connection, workspace, outbox, mode, palette ->
                ConnectionInputs(connection.phase, connection.error, connection.gateway?.name, mode, palette, workspace.allItems, workspace.boards.values.sumOf { it.size }, outbox.let { BackgroundPolicy.hasActiveWork(workspace.allItems, it) })
            }.collectLatest { inputs ->
                palette = inputs.palette
                if (inputs == lastRendered) return@collectLatest
                lastRendered = inputs
                startInForeground(connectionNotification(inputs))
            }
        }
    }

    private data class ConnectionInputs(
        val phase: ConnectionPhase,
        val error: String?,
        val gateway: String?,
        val mode: BackgroundMode,
        val palette: DieterPalette,
        val items: List<com.dbpprt.dieter.api.v1.Card>,
        val boards: Int,
        val activeWork: Boolean,
    )

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT -> {
                scope.launch { core.setConnected(false) }
                stopBackground()
                return START_NOT_STICKY
            }
            else -> {
                startInForeground(bootstrapNotification())
                policy.setServiceActive(true)
            }
        }
        return if (policy.desired.value && policy.mode.value.usesBackgroundService) START_STICKY else START_NOT_STICKY
    }

    private fun stopBackground() {
        policyJob?.cancel()
        policy.setPeriodicWindow(false)
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        policyJob?.cancel()
        renderJob?.cancel()
        releaseWakeLock()
        policy.setServiceActive(false)
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startInForeground(notification: Notification) {
        ServiceCompat.startForeground(
            this,
            CONNECTION_NOTIFICATION_ID,
            notification,
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING else 0,
        )
    }

    /** Wakes every minute for one core periodic window (up to 30 s, longer while agents work or changes are queued). */
    private suspend fun runPeriodicPolicy() {
        while (true) {
            whileWakeLockHeld {
                policy.setPeriodicWindow(true)
                try {
                    core.periodicWindow()
                } finally {
                    policy.setPeriodicWindow(false)
                }
            }
            delay(BackgroundPolicy.POLL_INTERVAL)
        }
    }

    private suspend fun whileWakeLockHeld(block: suspend () -> Unit) = coroutineScope {
        acquireWakeLock()
        val renewal = launch {
            while (true) {
                delay(WAKE_LOCK_RENEW_MS)
                acquireWakeLock()
            }
        }
        try {
            block()
        } finally {
            renewal.cancel()
            releaseWakeLock()
        }
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        val lock = wakeLock ?: getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:global-sync")
            .also { it.setReferenceCounted(false); wakeLock = it }
        if (lock.isHeld) lock.release()
        lock.acquire(WAKE_LOCK_TIMEOUT_MS)
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf(PowerManager.WakeLock::isHeld)?.release()
    }

    private fun connectionNotification(inputs: ConnectionInputs): Notification {
        val settings = NotificationSettings.load(core.platform.settings)
        val status = BackgroundStatus.of(inputs.phase, inputs.error, inputs.gateway, inputs.mode, inputs.items, inputs.boards, inputs.activeWork, settings)
        val accent = palette.tokens.shellStartInt
        val builder = Notification.Builder(this, AndroidNotifications.CONNECTION_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(status.title)
            .setContentText(status.summary)
            .setSubText(status.subtext)
            .setLargeIcon(connectionBadge(status.available))
            .setColor(accent)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(AndroidNotifications.openIntent(this, showConnection = !status.available))
            .addAction(Notification.Action.Builder(null, "Disconnect", serviceIntent(ACTION_DISCONNECT, 11)).build())
            .addAction(Notification.Action.Builder(null, "Open", AndroidNotifications.openIntent(this, showConnection = !status.available)).build())
        if (Build.VERSION.SDK_INT >= 36 && status.connected) {
            // Surface live agent work as an Android 16 promoted Live Update chip.
            if (Build.VERSION.SDK_INT_FULL >= Build.VERSION_CODES_FULL.BAKLAVA_1) builder.setRequestPromotedOngoing(true)
            if (status.running > 0) builder.setShortCriticalText("${status.running} active")
        }
        if (settings.style == NotificationStyle.DETAILED) {
            builder.setStyle(Notification.DecoratedCustomViewStyle())
            builder.setCustomBigContentView(expandedView(status))
        }
        return builder.build()
    }

    private fun bootstrapNotification(): Notification = Notification.Builder(this, AndroidNotifications.CONNECTION_CHANNEL)
        .setSmallIcon(R.drawable.ic_notification)
        .setContentTitle("Connecting to Dieter")
        .setContentText("Starting background synchronization")
        .setColor(palette.tokens.shellStartInt)
        .setCategory(Notification.CATEGORY_SERVICE)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setShowWhen(false)
        .setContentIntent(AndroidNotifications.openIntent(this))
        .build()

    /** Expanded shade body: board, review, and subagent pills. */
    private fun expandedView(status: BackgroundStatus): RemoteViews {
        val tokens = palette.tokens
        val view = RemoteViews(packageName, R.layout.notification_connection_expanded)
        view.setTextViewText(R.id.notification_title, status.title)
        view.setTextViewText(R.id.notification_text, status.summary)
        view.setTextViewText(R.id.notification_chip_boards, status.boardsLabel)
        val darkMode = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val neutralBackground = if (darkMode) tokens.darkRaisedInt else tokens.paneStartInt
        val neutralText = if (darkMode) tokens.paneStartInt else tokens.darkRaisedInt
        view.setTextColor(R.id.notification_chip_boards, neutralText)
        if (Build.VERSION.SDK_INT >= 31) {
            view.setColorStateList(R.id.notification_chip_boards, "setBackgroundTintList", ColorStateList.valueOf(neutralBackground))
        }
        status.reviewsLabel?.let { reviews ->
            view.setTextViewText(R.id.notification_chip_reviews, reviews)
            view.setViewVisibility(R.id.notification_chip_reviews, View.VISIBLE)
        }
        status.subagentsLabel?.let { subagents ->
            view.setTextViewText(R.id.notification_chip_subagents, subagents)
            view.setViewVisibility(R.id.notification_chip_subagents, View.VISIBLE)
        }
        return view
    }

    /** Rounded status tile shown as the large icon: bright when connected, muted when not. */
    private fun connectionBadge(connected: Boolean): android.graphics.drawable.Icon {
        val key = connected to palette.slug
        cachedBadge?.takeIf { it.first == key }?.second?.let { return it }
        val tokens = palette.tokens
        val size = 192
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), 52f, 52f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (connected) tokens.eyesTintInt else tokens.darkRaisedInt
        })
        val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (connected) tokens.eyesInt else tokens.mutedInt
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
        return android.graphics.drawable.Icon.createWithBitmap(bitmap).also { cachedBadge = key to it }
    }

    private fun serviceIntent(action: String, requestCode: Int) = android.app.PendingIntent.getService(
        this,
        requestCode,
        Intent(this, DieterSyncService::class.java).setAction(action),
        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        const val ACTION_DISCONNECT = "com.dbpprt.dieter.action.DISCONNECT"
        const val ACTION_CHAT_NOTIFICATION_DISMISSED = "com.dbpprt.dieter.action.CHAT_NOTIFICATION_DISMISSED"
        const val ACTION_MARK_CARD_DONE = "com.dbpprt.dieter.action.MARK_CARD_DONE"
        const val EXTRA_CARD_ID = "card_id"
        const val EXTRA_NOTIFICATION_TAG = "notification_tag"
        const val EXTRA_SHOW_CONNECTION = "show_connection"
        const val EXTRA_SESSION = "session"
        const val CONNECTION_NOTIFICATION_ID = 1001
        private const val WAKE_LOCK_TIMEOUT_MS = 15 * 60 * 1_000L
        private const val WAKE_LOCK_RENEW_MS = 10 * 60 * 1_000L

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, DieterSyncService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DieterSyncService::class.java))
        }
    }
}
