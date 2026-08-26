package com.dbpprt.dieter.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.R
import com.dbpprt.dieter.connection.DieterConnectionState
import com.dbpprt.dieter.connection.DieterSyncService
import com.dbpprt.dieter.data.DieterSyncStore
import com.dbpprt.dieter.settings.AppPreferences

/**
 * Home-screen activity feed. Renders entirely from the cached global-sync
 * projection, so it works offline; a refresh tap kicks the sync service to
 * pull a fresh frame.
 */
class DieterActivityWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        appWidgetIds.forEach { render(context, appWidgetManager, it) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        render(context, appWidgetManager, appWidgetId)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        DieterWidgetPrefs.delete(context, appWidgetIds)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) {
            requestSync(context)
            updateAll(context)
        }
    }

    companion object {
        const val ACTION_REFRESH = "com.dbpprt.dieter.widget.REFRESH"
        private const val COMPACT_MAX_WIDTH_DP = 200

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, DieterActivityWidgetProvider::class.java))
            ids.forEach { render(context, manager, it) }
        }

        fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
            val config = DieterWidgetPrefs.config(context, appWidgetId)
            val compact = isCompact(config.style, manager.getAppWidgetOptions(appWidgetId))
            val state = connectionState(context)
            val views = android.widget.RemoteViews(context.packageName, R.layout.widget_activity)
            val palette = AppPreferences.selectedPalette(context)
            val colors = palette.tokens
            val darkColors = palette.widgetUsesDarkColors(context)

            views.setInt(R.id.widget_root, "setBackgroundResource", palette.widgetBackground())
            views.setInt(R.id.widget_app_icon, "setBackgroundResource", palette.widgetAppChip())
            views.setInt(R.id.widget_app_icon, "setColorFilter", android.graphics.Color.WHITE)
            views.setInt(R.id.widget_refresh, "setColorFilter", colors.mutedForAppearanceInt(darkColors))
            views.setTextColor(R.id.widget_header_title, colors.textForAppearanceInt(darkColors))
            views.setTextColor(R.id.widget_empty_title, colors.textForAppearanceInt(darkColors))
            views.setTextColor(R.id.widget_empty_body, colors.mutedForAppearanceInt(darkColors))

            views.setTextViewText(
                R.id.widget_header_title,
                context.getString(if (compact) R.string.widget_title_last_finished else R.string.widget_title_activity),
            )
            val lastSyncAtMs = DieterWidgetPrefs.lastSyncAtMs(context)
            val now = java.time.Instant.now()
            val online = isOnline(lastSyncAtMs, now)
            views.setTextViewText(R.id.widget_status, "● " + statusLine(hostname(context, state), lastSyncAtMs, now))
            views.setTextColor(
                R.id.widget_status,
                if (online) colors.eyesForAppearanceInt(darkColors) else colors.mutedForAppearanceInt(darkColors),
            )
            views.setTextViewText(
                R.id.widget_empty_title,
                if (compact) "Nothing finished yet" else context.getString(R.string.widget_empty_title),
            )
            views.setTextViewText(
                R.id.widget_empty_body,
                if (compact) "Completed work shows up here" else context.getString(R.string.widget_empty_body),
            )

            val adapter = Intent(context, DieterWidgetService::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                .setData(Uri.parse("dieter-widget://list/$appWidgetId"))
            views.setRemoteAdapter(R.id.widget_list, adapter)
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)

            views.setOnClickPendingIntent(R.id.widget_refresh, refreshIntent(context))
            views.setOnClickPendingIntent(R.id.widget_header, openAppIntent(context))
            views.setOnClickPendingIntent(R.id.widget_empty, openAppIntent(context))
            views.setPendingIntentTemplate(R.id.widget_list, cardTemplateIntent(context, appWidgetId))

            manager.updateAppWidget(appWidgetId, views)
            manager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
        }

        internal fun isCompact(style: WidgetStyle, options: Bundle?): Boolean = when (style) {
            WidgetStyle.ACTIVITY -> false
            WidgetStyle.LAST_FINISHED -> true
            WidgetStyle.AUTO -> {
                val minWidth = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0) ?: 0
                minWidth in 1 until COMPACT_MAX_WIDTH_DP
            }
        }

        internal fun connectionState(context: Context): DieterConnectionState =
            (context.applicationContext as DieterApplication).container.connectionManager.state.value

        internal fun hostname(context: Context, state: DieterConnectionState): String? =
            state.projectHosts.values.firstOrNull { it.online }?.hostname
                ?: state.projectHosts.values.firstOrNull()?.hostname
                // Offline the manager drops hosts for cached projects; the
                // persisted machine directory still knows the machine name.
                ?: DieterSyncStore(context.applicationContext)
                    .loadMachineDirectory(state.activeGatewayId)
                    ?.hosts?.values?.firstOrNull()?.hostname

        private fun requestSync(context: Context) {
            val state = connectionState(context)
            if (state.desiredConnected && state.backgroundSyncEnabled) {
                // A widget tap grants a temporary background-start exemption;
                // guard anyway because doze can still reject the launch.
                runCatching { DieterSyncService.start(context) }
            }
        }

        private fun refreshIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context,
            1,
            Intent(context, DieterActivityWidgetProvider::class.java).setAction(ACTION_REFRESH),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        private fun openAppIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            2,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        /** Mutable template so per-row fill-in intents can carry the card id. */
        private fun cardTemplateIntent(context: Context, appWidgetId: Int): PendingIntent = PendingIntent.getActivity(
            context,
            100 + appWidgetId,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
    }
}
