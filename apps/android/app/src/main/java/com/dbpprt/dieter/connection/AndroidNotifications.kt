package com.dbpprt.dieter.connection

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.style.StyleSpan
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.R
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.notifications.NotificationAction
import com.dbpprt.dieter.core.notifications.NotificationContent
import com.dbpprt.dieter.core.notifications.NotificationKind
import com.dbpprt.dieter.core.notifications.NotificationRole
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.notifications.NotificationSink
import com.dbpprt.dieter.core.notifications.NotificationStyle
import com.dbpprt.dieter.core.notifications.ResultSummary
import com.dbpprt.dieter.core.notifications.SummaryAction
import com.dbpprt.dieter.core.notifications.resultSummaryAction
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.settings.DieterPalette

/**
 * Renders the core's notification plan (running chats, results, review
 * requests) as Android notifications. The core decides what to post; this
 * class owns channels, colors, intents, the per-session dismissal of running
 * chats, and the grouped results summary.
 */
class AndroidNotifications(context: Context) : NotificationSink {
    private val context = context.applicationContext
    private val notifications = NotificationManagerCompat.from(this.context)
    private var core: CoreRuntime? = null
    private var preferences: AppPreferences? = null
    private val summarized = HashSet<String>()

    init {
        createChannels(this.context)
    }

    fun bind(core: CoreRuntime, preferences: AppPreferences) {
        this.core = core
        this.preferences = preferences
    }

    private val palette: DieterPalette get() = preferences?.palette?.value ?: DieterPalette.DEFAULT
    private val accent: Int get() = palette.tokens.shellStartInt
    private val settings: NotificationSettings get() = core?.let { NotificationSettings.load(it.platform.settings) } ?: NotificationSettings()

    override fun post(content: NotificationContent): Boolean {
        val notification = when (content.kind) {
            NotificationKind.RUNNING -> running(content, content.cardId, content.session ?: content.cardId)
            NotificationKind.REVIEW -> review(content, content.cardId)
            NotificationKind.RESULT -> result(content, content.cardId)
        }
        val posted = notify(content.key, notification)
        if (posted && content.role == NotificationRole.RESULTS) reconcileSummary()
        return posted
    }

    override fun cancel(key: String) {
        notifications.cancel(key, CONTENT_ID)
        if (NotificationContent.runningCardId(key) == null) reconcileSummary()
    }

    private fun running(content: NotificationContent, cardId: String, session: String): Notification {
        val builder = Notification.Builder(context, RUNNING_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(content.title)
            .setContentText(content.text)
            .setSubText(content.expanded)
            .setColor(accent)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setAutoCancel(false)
            .setOngoing(false)
            .setContentIntent(openIntent(context, cardId))
            .setDeleteIntent(dismissIntent(content.key, cardId, session))
        if (settings.style == NotificationStyle.DETAILED && Build.VERSION.SDK_INT >= 36) {
            builder.setStyle(Notification.ProgressStyle().setProgressIndeterminate(true).setStyledByProgress(false))
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun result(content: NotificationContent, cardId: String): Notification {
        val builder = Notification.Builder(context, RESULTS_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(content.title)
            .setContentText(content.text)
            .setColor(accent)
            .setCategory(Notification.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setGroup(RESULTS_GROUP)
            .setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .setContentIntent(openIntent(context, cardId))
        content.expanded?.let { preview ->
            builder.setStyle(Notification.BigTextStyle().bigText(bold(content.text).append("\n").append(preview)))
        }
        return builder.build()
    }

    private fun review(content: NotificationContent, cardId: String): Notification {
        val builder = Notification.Builder(context, RESULTS_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(content.title)
            .setContentText(content.text)
            .setColor(REVIEW_ACCENT)
            .setCategory(Notification.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setGroup(RESULTS_GROUP)
            .setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .setContentIntent(openIntent(context, cardId))
        content.actions.forEach { action ->
            val intent = when (action) {
                NotificationAction.MARK_DONE -> markDoneIntent(content.key, cardId)
                NotificationAction.OPEN -> openIntent(context, cardId)
            }
            builder.addAction(Notification.Action.Builder(null, action.title, intent).build())
        }
        content.expanded?.let { summary ->
            builder.setStyle(Notification.BigTextStyle().bigText(bold(content.text).append("\n").append(summary)))
        }
        return builder.build()
    }

    private fun bold(text: String) = SpannableStringBuilder().append(text, StyleSpan(Typeface.BOLD), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)

    /** Collapses two or more results into one silent stack. */
    private fun reconcileSummary() {
        val active = context.getSystemService(NotificationManager::class.java).activeNotifications
        val children = active.asSequence()
            .filter { it.notification.group == RESULTS_GROUP && it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 }
            .mapNotNullTo(HashSet()) { it.tag }
        val summaryActive = active.any { it.id == RESULTS_SUMMARY_ID && it.tag == null }
        when (resultSummaryAction(children, summarized, summaryActive)) {
            SummaryAction.UNCHANGED -> Unit
            SummaryAction.CANCEL -> {
                notifications.cancel(RESULTS_SUMMARY_ID)
                summarized.clear()
            }
            SummaryAction.POST -> {
                val wording = ResultSummary.of(children.size)
                val summary = Notification.Builder(context, RESULTS_CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(wording.title)
                    .setContentText(wording.text)
                    .setColor(accent)
                    .setCategory(Notification.CATEGORY_STATUS)
                    .setGroup(RESULTS_GROUP)
                    .setGroupSummary(true)
                    .setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
                    .setAutoCancel(true)
                    .setOnlyAlertOnce(true)
                    .setShowWhen(false)
                    .setNumber(children.size)
                    .setContentIntent(openIntent(context))
                    .build()
                if (notify(null, summary, RESULTS_SUMMARY_ID)) {
                    summarized.clear()
                    summarized += children
                }
            }
        }
    }

    private fun dismissIntent(key: String, cardId: String, session: String): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode(key),
        Intent(context, NotificationDismissedReceiver::class.java)
            .setAction(DieterSyncService.ACTION_CHAT_NOTIFICATION_DISMISSED)
            .putExtra(DieterSyncService.EXTRA_CARD_ID, cardId)
            .putExtra(DieterSyncService.EXTRA_SESSION, session),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun markDoneIntent(key: String, cardId: String): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode(key),
        Intent(context, NotificationActionReceiver::class.java)
            .setAction(DieterSyncService.ACTION_MARK_CARD_DONE)
            .putExtra(DieterSyncService.EXTRA_CARD_ID, cardId)
            .putExtra(DieterSyncService.EXTRA_NOTIFICATION_TAG, key),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** One request code per notification, so each keeps its own extras; extras alone never tell PendingIntents apart. */
    private fun requestCode(key: String): Int = key.hashCode() and 0x7fffffff

    private fun canPost(): Boolean =
        Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    private fun notify(tag: String?, notification: Notification, id: Int = CONTENT_ID): Boolean {
        if (!canPost()) return false
        return try {
            notifications.notify(tag, id, notification)
            true
        } catch (_: SecurityException) {
            // Permission can be revoked between the check and the post.
            false
        }
    }

    companion object {
        const val CONNECTION_CHANNEL = "dieter_connection"
        const val RUNNING_CHANNEL = "dieter_agent_running"
        const val RESULTS_CHANNEL = "dieter_agent_activity"
        private const val RESULTS_GROUP = "dieter_agent_results"
        private const val RESULTS_SUMMARY_ID = 1002
        private val REVIEW_ACCENT = Color.rgb(226, 190, 106)

        /** The ID of every notification the core plans; its key is the notification's tag. */
        const val CONTENT_ID = 20_000

        fun openIntent(context: Context, cardId: String = "", showConnection: Boolean = false): PendingIntent {
            val intent = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(DieterSyncService.EXTRA_CARD_ID, cardId)
                .putExtra(DieterSyncService.EXTRA_SHOW_CONNECTION, showConnection)
            return PendingIntent.getActivity(
                context,
                ((cardId.hashCode() * 31 + if (showConnection) 1 else 0) and 0x7fffffff),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun createChannels(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CONNECTION_CHANNEL, "Dieter connection", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Permanent status while Dieter stays connected"
                    setShowBadge(false)
                },
            )
            manager.createNotificationChannel(
                NotificationChannel(RUNNING_CHANNEL, "Running chats", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Silent progress while standalone chats are running"
                    setSound(null, null)
                    enableVibration(false)
                },
            )
            manager.createNotificationChannel(
                NotificationChannel(RESULTS_CHANNEL, "Agent results", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "Completion, failure, stopped, needs-you, and review updates"
                },
            )
        }
    }
}
