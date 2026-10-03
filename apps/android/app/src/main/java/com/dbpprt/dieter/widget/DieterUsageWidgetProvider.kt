package com.dbpprt.dieter.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.R
import com.dbpprt.dieter.core.activity.WidgetModel
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.quotas.QuotaLevel
import com.dbpprt.dieter.core.quotas.UsageWidget
import com.dbpprt.dieter.core.quotas.UsageWidgetAccount
import com.dbpprt.dieter.core.quotas.UsageWidgetModel
import com.dbpprt.dieter.settings.AppPreferences
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * Home-screen usage widget for every Dieter account: a small 2×2 headline
 * variant and a larger per-account variant. Data comes from the gateway's
 * normalized credential-free provider quota snapshots; the last fetched
 * groups and their fetch time are cached in [WidgetUsagePrefs] because the
 * gateway stores no client state. The core's [UsageWidget] builds the rows.
 */
open class DieterUsageWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        appWidgetIds.forEach { render(context, appWidgetManager, it) }
    }

    override fun onAppWidgetOptionsChanged(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle) {
        render(context, appWidgetManager, appWidgetId)
    }

    // The shared usage cache outlives individual widgets by design; nothing
    // per-instance is stored, so there is nothing to clean up on deletion.

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action !in setOf(ACTION_REFRESH, AppWidgetManager.ACTION_APPWIDGET_UPDATE) ||
            !refreshing.compareAndSet(false, true)) return
        val pending = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            try {
                updateAll(appContext)
                val success = runCatching {
                    fetch(appContext, requestRefresh = intent.action == ACTION_REFRESH)
                }.onFailure { error ->
                    val core = (appContext as com.dbpprt.dieter.DieterApplication).container.core
                    android.util.Log.w("UsageWidget", "Refresh failed: ${error.javaClass.simpleName}, phase=${core.connection.state.value.phase}, live=${core.quotas.view.value.live}, loading=${core.quotas.view.value.loading}")
                }.getOrDefault(false)
                failedRefreshAt = if (success) 0 else System.currentTimeMillis()
            } finally {
                refreshing.set(false)
                try { updateAll(appContext) } finally { pending.finish() }
            }
        }
    }

    companion object {
        const val ACTION_REFRESH = "com.dbpprt.dieter.widget.USAGE_REFRESH"
        const val EXTRA_OPEN_ACCOUNTS = "com.dbpprt.dieter.widget.OPEN_ACCOUNTS"
        private val refreshing = AtomicBoolean(false)
        @Volatile private var failedRefreshAt = 0L

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            renderProvider(context, manager, DieterUsageWidgetProvider::class.java, pinnedSmall = false)
            renderProvider(context, manager, DieterUsageSmallWidgetProvider::class.java, pinnedSmall = true)
        }

        private fun renderProvider(
            context: Context,
            manager: AppWidgetManager,
            provider: Class<out AppWidgetProvider>,
            pinnedSmall: Boolean,
        ) {
            manager.getAppWidgetIds(ComponentName(context, provider)).forEach { id ->
                render(context, manager, id, pinnedSmall)
            }
        }

        internal fun connected(context: Context): Boolean = runCatching {
            val state = (context.applicationContext as com.dbpprt.dieter.DieterApplication).container.core.connection.state.value
            state.phase == ConnectionPhase.CONNECTED
        }.getOrDefault(false)

        /** Cheap list from the gateway snapshot store; [requestRefresh] asks providers for fresh data. */
        internal suspend fun fetch(context: Context, requestRefresh: Boolean): Boolean {
            val container = (context.applicationContext as com.dbpprt.dieter.DieterApplication).container
            val core = container.core
            if (!core.accounts.state.value.wantsConnection) return false
            return container.policy.withWidgetRefresh {
                withTimeout(8_000) {
                    if (!core.connection.refreshForWidget(8.seconds)) return@withTimeout false
                    // load() is a no-op before the quota client is attached, or
                    // while its initial read is running. Wait for a real frame.
                    core.quotas.view.first { it.live && !it.loading && it.mutating.isEmpty() }
                    val response = core.onCore {
                        if (requestRefresh) core.quotas.load(refresh = true)
                        core.quotas.view.value
                    }
                    if (!response.live || response.error != null) return@withTimeout false
                    WidgetUsagePrefs.saveCache(context, response.groups, System.currentTimeMillis())
                    true
                }
            }
        }

        fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int, pinnedSmall: Boolean = false) {
            val options = manager.getAppWidgetOptions(appWidgetId)
            val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
            val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
            // The dedicated small provider always renders small; the standard
            // provider infers the variant from the widget's current bounds.
            val small = pinnedSmall || minWidth in 1 until 180 || minHeight in 1 until 180

            val model = UsageWidget.build(
                groups = WidgetUsagePrefs.cachedGroups(context),
                fetchedTime = widgetTime(WidgetUsagePrefs.fetchedAt(context)),
                connected = connected(context),
                small = small,
                now = Clock.System.now(),
            )
            val views = renderViews(context, model, small)
            views.setOnClickPendingIntent(R.id.widget_usage_refresh, PendingIntent.getBroadcast(context, 11,
                Intent(context, DieterUsageWidgetProvider::class.java).setAction(ACTION_REFRESH),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            val open = PendingIntent.getActivity(context, 12, accountsIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(if (small) R.id.widget_usage_body else R.id.widget_usage_header, open)
            if (small) views.setOnClickPendingIntent(R.id.widget_usage_empty, open)
            manager.updateAppWidget(appWidgetId, views)
        }

        private fun renderViews(context: Context, model: UsageWidgetModel, small: Boolean): RemoteViews {
            val palette = AppPreferences.selectedPalette(context)
            val colors = palette.tokens
            val darkColors = palette.widgetUsesDarkColors(context)
            val textColor = colors.textForAppearanceInt(darkColors)
            val mutedColor = colors.mutedForAppearanceInt(darkColors)
            val views = RemoteViews(context.packageName, if (small) R.layout.widget_usage_small else R.layout.widget_usage)
            views.setInt(R.id.widget_usage_root, "setBackgroundResource", palette.widgetBackground())
            views.setInt(R.id.widget_usage_app_icon, "setBackgroundResource", palette.widgetAppChip())
            views.setInt(R.id.widget_usage_app_icon, "setColorFilter", android.graphics.Color.WHITE)
            views.setInt(R.id.widget_usage_refresh, "setColorFilter", mutedColor)

            val empty = !model.hasAccounts
            if (small) {
                views.setViewVisibility(R.id.widget_usage_body, if (empty) View.GONE else View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_usage_list, if (empty) View.GONE else View.VISIBLE)
                views.setViewVisibility(R.id.widget_usage_rows, if (empty) View.GONE else View.VISIBLE)
            }
            views.setViewVisibility(R.id.widget_usage_empty, if (empty) View.VISIBLE else View.GONE)
            views.setTextColor(R.id.widget_usage_empty_title, textColor)
            views.setTextColor(R.id.widget_usage_empty_body, mutedColor)
            views.setTextViewText(R.id.widget_usage_empty_title, model.emptyTitle)
            views.setTextViewText(R.id.widget_usage_empty_body, model.emptyBody)
            views.setTextViewText(R.id.widget_usage_status, WidgetModel.status(
                model.statusText, refreshing.get(),
                refreshFailed = failedRefreshAt > 0 && failedRefreshAt > WidgetUsagePrefs.fetchedAt(context),
            ))
            views.setTextColor(R.id.widget_usage_status, mutedColor)
            views.setBoolean(R.id.widget_usage_refresh, "setEnabled", !refreshing.get())
            views.setContentDescription(R.id.widget_usage_header, context.getString(R.string.widget_usage_open_accounts))

            if (small) {
                renderSmall(context, views, model, darkColors, textColor, mutedColor)
            } else {
                views.setTextColor(R.id.widget_usage_title, textColor)
                views.setTextColor(R.id.widget_usage_summary, mutedColor)
                views.setTextViewText(R.id.widget_usage_summary, model.summary)
                renderLarge(context, views, model, darkColors)
            }
            return views
        }

        /** Small variant: the binding number for every account, one tap away from the app. */
        private fun renderSmall(
            context: Context,
            views: RemoteViews,
            model: UsageWidgetModel,
            darkColors: Boolean,
            textColor: Int,
            mutedColor: Int,
        ) {
            val lowest = model.lowest
            val percentText = when {
                lowest != null -> "${lowest.remainingPercent}%"
                model.hasAccounts -> "· ·"
                else -> "–"
            }
            views.setTextViewText(R.id.widget_usage_percent, percentText)
            views.setTextColor(R.id.widget_usage_percent, levelColor(model.level, darkColors, textColor))
            views.setTextViewText(R.id.widget_usage_source, when {
                lowest != null -> context.getString(R.string.widget_usage_lowest, lowest.source)
                model.hasAccounts -> "Percentages not reported"
                else -> ""
            })
            views.setTextColor(R.id.widget_usage_source, mutedColor)
            views.setInt(R.id.widget_usage_bar, "setMax", 100)
            views.setInt(R.id.widget_usage_bar, "setProgress", lowest?.remainingPercent ?: 0)
            levelTint(views, R.id.widget_usage_bar, model.level, darkColors, mutedColor)
            views.setTextViewText(R.id.widget_usage_reset, lowest?.resetLine.orEmpty())
            views.setTextColor(R.id.widget_usage_reset, mutedColor)
        }

        /** Large variant: one row per account, most constrained window binding. */
        private fun renderLarge(context: Context, views: RemoteViews, model: UsageWidgetModel, darkColors: Boolean) {
            val summary = listOfNotNull(
                model.summary.takeIf { model.hasAccounts },
                context.getString(R.string.widget_usage_hidden, model.hiddenAccounts).takeIf { model.hiddenAccounts > 0 },
            ).joinToString(" · ")
            views.setTextViewText(R.id.widget_usage_summary, summary)
            if (Build.VERSION.SDK_INT >= 31) {
                views.setViewVisibility(R.id.widget_usage_rows, View.GONE)
                views.setViewVisibility(R.id.widget_usage_list, if (model.hasAccounts) View.VISIBLE else View.GONE)
                val items = RemoteViews.RemoteCollectionItems.Builder().setViewTypeCount(1).setHasStableIds(true)
                model.accounts.forEachIndexed { index, account ->
                    items.addItem(index.toLong(), usageAccountRow(context, account, darkColors))
                }
                views.setRemoteAdapter(R.id.widget_usage_list, items.build())
            } else {
                views.setViewVisibility(R.id.widget_usage_list, View.GONE)
                views.setViewVisibility(R.id.widget_usage_rows, if (model.hasAccounts) View.VISIBLE else View.GONE)
                views.removeAllViews(R.id.widget_usage_rows)
                model.accounts.take(3).forEach { account ->
                    views.addView(R.id.widget_usage_rows, usageAccountRow(context, account, darkColors))
                }
            }
        }

        private fun usageAccountRow(context: Context, account: UsageWidgetAccount, darkColors: Boolean): RemoteViews {
            val palette = AppPreferences.selectedPalette(context)
            val colors = palette.tokens
            val views = RemoteViews(context.packageName, R.layout.widget_usage_row)
            views.setTextViewText(R.id.widget_usage_row_provider, account.providerName)
            views.setTextColor(R.id.widget_usage_row_provider, colors.textForAppearanceInt(darkColors))
            val percent = account.remainingPercent
            views.setTextViewText(R.id.widget_usage_row_percent, if (percent != null) "$percent%" else "—")
            views.setTextColor(R.id.widget_usage_row_percent, levelColor(account.level, darkColors, colors.textForAppearanceInt(darkColors)))
            views.setTextViewText(R.id.widget_usage_row_title, account.title)
            views.setTextColor(R.id.widget_usage_row_title, colors.mutedForAppearanceInt(darkColors))
            views.setInt(R.id.widget_usage_row_bar, "setMax", 100)
            views.setInt(R.id.widget_usage_row_bar, "setProgress", percent ?: 0)
            levelTint(views, R.id.widget_usage_row_bar, account.level, darkColors, colors.mutedForAppearanceInt(darkColors))
            views.setTextViewText(R.id.widget_usage_row_reset,
                account.availabilityText ?: account.resetLine.ifEmpty { "Percentages not reported" })
            views.setTextColor(R.id.widget_usage_row_reset, colors.mutedForAppearanceInt(darkColors))
            views.setContentDescription(R.id.widget_usage_row_root,
                listOf(account.providerName, account.title,
                    account.remainingPercent?.let { "$it% remaining" } ?: account.availabilityText,
                    account.resetLine).filterNotNull().filter(String::isNotBlank).joinToString(", "))
            return views
        }

        /** The colour of a quota [level]: coral when critical, amber when low, [fallback] otherwise. */
        private fun levelColor(level: QuotaLevel, darkColors: Boolean, fallback: Int): Int = when (level) {
            QuotaLevel.CRITICAL -> if (darkColors) 0xFFF1868E.toInt() else 0xFFBA1A1A.toInt()
            QuotaLevel.LOW -> if (darkColors) 0xFFE2BE6A.toInt() else 0xFF805500.toInt()
            QuotaLevel.NORMAL, QuotaLevel.UNKNOWN -> fallback
        }

        /** Level-tinted progress, palette-muted unless low or critical. */
        private fun levelTint(views: RemoteViews, viewId: Int, level: QuotaLevel, darkColors: Boolean, fallback: Int) {
            if (Build.VERSION.SDK_INT >= 31) {
                views.setColorStateList(viewId, "setProgressTintList",
                    android.content.res.ColorStateList.valueOf(levelColor(level, darkColors, fallback)))
            }
        }

        private fun accountsIntent(context: Context) = Intent(context, MainActivity::class.java)
            .putExtra(EXTRA_OPEN_ACCOUNTS, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}

/**
 * Manifest-level second provider so the picker offers the small 2×2 usage
 * variant explicitly; it pins with the small preview and the same engine.
 */
class DieterUsageSmallWidgetProvider : DieterUsageWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        appWidgetIds.forEach { id -> DieterUsageWidgetProvider.render(context, appWidgetManager, id, pinnedSmall = true) }
    }

    override fun onAppWidgetOptionsChanged(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle) {
        DieterUsageWidgetProvider.render(context, appWidgetManager, appWidgetId, pinnedSmall = true)
    }
}
