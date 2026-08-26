package com.dbpprt.dieter.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.dbpprt.dieter.R
import com.dbpprt.dieter.connection.DieterSyncService
import com.dbpprt.dieter.settings.AppPreferences

class DieterWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = ActivityRemoteViewsFactory(
        applicationContext,
        intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID),
    )
}

internal class ActivityRemoteViewsFactory(
    private val context: Context,
    private val appWidgetId: Int,
) : RemoteViewsService.RemoteViewsFactory {
    private var rows: List<WidgetRow> = emptyList()
    private var compact = false
    private val palette get() = AppPreferences.selectedPalette(context)
    private val colors get() = palette.tokens
    private val darkColors get() = palette.widgetUsesDarkColors(context)

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        val config = DieterWidgetPrefs.config(context, appWidgetId)
        val options = AppWidgetManager.getInstance(context)?.getAppWidgetOptions(appWidgetId)
        compact = DieterActivityWidgetProvider.isCompact(config.style, options)
        val state = DieterActivityWidgetProvider.connectionState(context)
        rows = buildWidgetModel(
            cards = state.cards,
            chats = state.chats,
            conversations = state.activeConversations,
            projects = state.projects,
            hostname = DieterActivityWidgetProvider.hostname(context, state),
            lastSyncAtMs = DieterWidgetPrefs.lastSyncAtMs(context),
            config = config,
            compact = compact,
        ).rows
    }

    override fun getCount(): Int = rows.size

    override fun getViewAt(position: Int): RemoteViews {
        return when (val row = rows.getOrNull(position)) {
            is WidgetRow.Section -> RemoteViews(context.packageName, R.layout.widget_row_section).apply {
                setTextViewText(R.id.widget_section_title, row.title)
                setTextColor(R.id.widget_section_title, colors.tertiaryForAppearanceInt(darkColors))
            }
            is WidgetRow.Item -> itemView(row)
            null -> RemoteViews(context.packageName, R.layout.widget_row_section)
        }
    }

    private fun itemView(row: WidgetRow.Item): RemoteViews {
        val layout = if (compact) R.layout.widget_row_compact else R.layout.widget_row_item
        val views = RemoteViews(context.packageName, layout)
        views.setTextViewText(R.id.widget_row_title, row.title)
        views.setTextViewText(R.id.widget_row_trailing, row.trailing)
        views.setTextColor(R.id.widget_row_title, colors.textForAppearanceInt(darkColors))
        views.setImageViewResource(R.id.widget_row_icon, iconRes(row.kind))
        views.setInt(R.id.widget_row_icon, "setColorFilter", iconColor(row.kind))
        views.setInt(R.id.widget_row_icon, "setBackgroundResource", iconBgRes(row.kind))
        views.setTextColor(R.id.widget_row_trailing, trailingColor(row.kind))
        if (!compact) {
            views.setTextViewText(R.id.widget_row_subtitle, row.subtitle)
            views.setTextColor(R.id.widget_row_subtitle, colors.mutedForAppearanceInt(darkColors))
            views.setInt(
                R.id.widget_row_root,
                "setBackgroundResource",
                if (row.highlighted) R.drawable.bg_widget_row_highlight else 0,
            )
        }
        views.setOnClickFillInIntent(
            R.id.widget_row_root,
            Intent().putExtra(DieterSyncService.EXTRA_CARD_ID, row.cardId),
        )
        return views
    }

    private fun iconRes(kind: WidgetRowKind): Int = when (kind) {
        WidgetRowKind.WAITING, WidgetRowKind.REVIEW -> R.drawable.ic_widget_eye
        WidgetRowKind.RUNNING -> R.drawable.ic_widget_running
        WidgetRowKind.CHAT -> R.drawable.ic_widget_chat
        WidgetRowKind.DONE, WidgetRowKind.FAILED -> R.drawable.ic_widget_check
    }

    private fun iconColor(kind: WidgetRowKind): Int = when (kind) {
        WidgetRowKind.WAITING, WidgetRowKind.REVIEW -> 0xFFE2BE6A.toInt()
        WidgetRowKind.RUNNING -> colors.liveForAppearanceInt(darkColors)
        WidgetRowKind.DONE -> colors.eyesForAppearanceInt(darkColors)
        WidgetRowKind.FAILED -> 0xFFF1868E.toInt()
        WidgetRowKind.CHAT -> colors.mutedForAppearanceInt(darkColors)
    }

    private fun iconBgRes(kind: WidgetRowKind): Int = when (kind) {
        WidgetRowKind.WAITING, WidgetRowKind.REVIEW -> R.drawable.bg_widget_icon_amber
        WidgetRowKind.RUNNING -> palette.widgetIconBackground()
        WidgetRowKind.DONE -> palette.widgetIconBackground()
        WidgetRowKind.FAILED -> R.drawable.bg_widget_icon_coral
        WidgetRowKind.CHAT -> palette.widgetIconBackground()
    }

    private fun trailingColor(kind: WidgetRowKind): Int = when (kind) {
        WidgetRowKind.WAITING, WidgetRowKind.REVIEW -> 0xFFE2BE6A.toInt()
        WidgetRowKind.RUNNING -> colors.liveForAppearanceInt(darkColors)
        WidgetRowKind.FAILED -> 0xFFF1868E.toInt()
        else -> colors.mutedForAppearanceInt(darkColors)
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 3

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = false

    override fun onDestroy() = Unit
}
