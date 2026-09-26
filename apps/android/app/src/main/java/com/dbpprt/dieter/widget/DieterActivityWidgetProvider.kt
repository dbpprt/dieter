package com.dbpprt.dieter.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.R
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.DieterConnectionState
import com.dbpprt.dieter.settings.AppPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicBoolean

/** A cached Inbox, refreshed by applied workspace changes or an explicit user tap. */
class DieterActivityWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        appWidgetIds.forEach { render(context, appWidgetManager, it) }
    }

    override fun onAppWidgetOptionsChanged(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle) {
        render(context, appWidgetManager, appWidgetId)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) = DieterWidgetPrefs.delete(context, appWidgetIds)

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_REFRESH || !refreshing.compareAndSet(false, true)) return
        val pending = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            try {
                updateAll(appContext)
                val success = runCatching {
                    withTimeout(8_000) {
                        (appContext as DieterApplication).container.connectionManager.refreshForWidget()
                    }
                }.getOrDefault(false)
                failedRefreshAt = if (success) 0 else System.currentTimeMillis()
                failedRefreshGateway = connectionState(appContext).activeGatewayId
            } finally {
                refreshing.set(false)
                try { updateAll(appContext) } finally { pending.finish() }
            }
        }
    }

    companion object {
        const val ACTION_REFRESH = "com.dbpprt.dieter.widget.REFRESH"
        const val EXTRA_OPEN_INBOX = "com.dbpprt.dieter.widget.OPEN_INBOX"
        private val refreshing = AtomicBoolean(false)
        @Volatile private var failedRefreshAt = 0L
        @Volatile private var failedRefreshGateway = ""

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            manager.getAppWidgetIds(ComponentName(context, DieterActivityWidgetProvider::class.java))
                .forEach { render(context, manager, it) }
        }

        internal fun model(state: DieterConnectionState, config: WidgetConfig, compact: Boolean) = buildWidgetModel(
            cards = state.cards + state.chats,
            conversations = state.activeConversations,
            projects = state.projects,
            lastSyncAtMs = state.lastConnectedAtMs ?: 0L,
            connected = state.phase == ConnectionPhase.CONNECTED,
            config = config,
            compact = compact,
        )

        fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
            val config = DieterWidgetPrefs.config(context, appWidgetId)
            val compact = isCompact(config.style, manager.getAppWidgetOptions(appWidgetId))
            val state = connectionState(context)
            val model = model(state, config, compact)
            val views = RemoteViews(context.packageName, R.layout.widget_activity)
            val palette = AppPreferences.selectedPalette(context)
            val colors = palette.tokens
            val darkColors = palette.widgetUsesDarkColors(context)
            val textColor = colors.textForAppearanceInt(darkColors)
            val mutedColor = colors.mutedForAppearanceInt(darkColors)
            views.setInt(R.id.widget_root, "setBackgroundResource", palette.widgetBackground())
            views.setInt(R.id.widget_app_icon, "setBackgroundResource", palette.widgetAppChip())
            views.setInt(R.id.widget_app_icon, "setColorFilter", android.graphics.Color.WHITE)
            views.setInt(R.id.widget_refresh, "setColorFilter", mutedColor)
            views.setTextColor(R.id.widget_header_title, textColor)
            views.setTextColor(R.id.widget_summary, mutedColor)
            views.setTextColor(R.id.widget_status, mutedColor)
            views.setTextColor(R.id.widget_empty_title, textColor)
            views.setTextColor(R.id.widget_empty_body, mutedColor)
            views.setTextViewText(R.id.widget_header_title, model.headerTitle)
            views.setTextViewText(R.id.widget_summary, model.summary)
            views.setViewVisibility(R.id.widget_app_icon, if (compact) View.GONE else View.VISIBLE)
            views.setBoolean(R.id.widget_summary, "setSingleLine", !compact)
            views.setInt(R.id.widget_summary, "setMaxLines", if (compact) 2 else 1)
            views.setTextViewText(R.id.widget_status, when {
                refreshing.get() -> "Refreshing…"
                failedRefreshGateway == state.activeGatewayId && failedRefreshAt > (state.lastConnectedAtMs ?: 0) -> "Couldn’t refresh"
                else -> model.statusText
            })
            views.setTextViewText(R.id.widget_empty_title, model.emptyTitle)
            views.setTextViewText(R.id.widget_empty_body, model.emptyBody)
            views.setBoolean(R.id.widget_refresh, "setEnabled", !refreshing.get())
            views.setContentDescription(R.id.widget_header, "Open Inbox. ${model.summary}")

            if (Build.VERSION.SDK_INT >= 31) {
                // One immutable snapshot prevents an old RemoteViewsService
                // dataset from surviving a newer header, archive or account switch.
                val renderer = WidgetRowRenderer(context, compact)
                val items = RemoteViews.RemoteCollectionItems.Builder().setViewTypeCount(3).setHasStableIds(true)
                model.rows.forEach { row -> items.addItem(row.stableId(), renderer.view(row)) }
                views.setRemoteAdapter(R.id.widget_list, items.build())
            } else {
                val adapter = Intent(context, DieterWidgetService::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                    .setData(Uri.parse("dieter-widget://list/$appWidgetId"))
                views.setRemoteAdapter(R.id.widget_list, adapter)
            }
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)
            views.setOnClickPendingIntent(R.id.widget_refresh, PendingIntent.getBroadcast(context, 1,
                Intent(context, DieterActivityWidgetProvider::class.java).setAction(ACTION_REFRESH),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            val open = PendingIntent.getActivity(context, 2, inboxIntent(context), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.widget_header, open)
            views.setOnClickPendingIntent(R.id.widget_empty, open)
            views.setPendingIntentTemplate(R.id.widget_list, PendingIntent.getActivity(context, 100 + appWidgetId,
                inboxIntent(context), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
            manager.updateAppWidget(appWidgetId, views)
            if (Build.VERSION.SDK_INT < 31) manager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
        }

        internal fun isCompact(style: WidgetStyle, options: Bundle?): Boolean = when (style) {
            WidgetStyle.ACTIVITY -> false
            WidgetStyle.LAST_FINISHED -> true
            WidgetStyle.AUTO -> (options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0) ?: 0) in 1 until 240 ||
                (options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0) ?: 0) in 1 until 200
        }

        internal fun connectionState(context: Context): DieterConnectionState =
            (context.applicationContext as DieterApplication).container.connectionManager.state.value

        private fun inboxIntent(context: Context) = Intent(context, MainActivity::class.java)
            .putExtra(EXTRA_OPEN_INBOX, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}

/** Stable across reordering, including section rows; independent of a list position. */
private fun WidgetRow.stableId(): Long {
    val key = when (this) { is WidgetRow.Item -> "item:$cardId"; is WidgetRow.Section -> "section:${title.substringBefore(" ·")}" }
    return key.fold(-3750763034362895579L) { hash, char -> (hash xor char.code.toLong()) * 1099511628211L }
}
