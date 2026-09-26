package com.dbpprt.dieter.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.view.View
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

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        val config = DieterWidgetPrefs.config(context, appWidgetId)
        val options = AppWidgetManager.getInstance(context)?.getAppWidgetOptions(appWidgetId)
        compact = DieterActivityWidgetProvider.isCompact(config.style, options)
        val state = DieterActivityWidgetProvider.connectionState(context)
        rows = buildWidgetModel(
            cards = state.cards + state.chats,
            conversations = state.activeConversations,
            projects = state.projects,
            lastSyncAtMs = state.lastConnectedAtMs ?: 0L,
            connected = state.phase == com.dbpprt.dieter.connection.ConnectionPhase.CONNECTED,
            config = config,
            compact = compact,
        ).rows
    }

    override fun getCount(): Int = rows.size

    override fun getViewAt(position: Int): RemoteViews = rows.getOrNull(position)?.let {
        WidgetRowRenderer(context, compact).view(it)
    } ?: RemoteViews(context.packageName, R.layout.widget_row_section)

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 3

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = false

    override fun onDestroy() = Unit
}

internal class WidgetRowRenderer(private val context: Context, private val compact: Boolean) {
    private val palette get() = AppPreferences.selectedPalette(context)
    private val colors get() = palette.tokens
    private val darkColors get() = palette.widgetUsesDarkColors(context)

    fun view(row: WidgetRow): RemoteViews {
        return when (row) {
            is WidgetRow.Section -> RemoteViews(context.packageName, R.layout.widget_row_section).apply {
                setTextViewText(R.id.widget_section_title, row.title)
                setTextColor(R.id.widget_section_title, colors.tertiaryForAppearanceInt(darkColors))
            }
            is WidgetRow.Item -> itemView(row)
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
        views.setViewVisibility(R.id.widget_row_trailing, if (compact) View.GONE else View.VISIBLE)
        views.setTextViewText(R.id.widget_row_subtitle, if (compact) listOf(row.detail,
            row.trailing.takeUnless { it == "Just now" }.orEmpty()).filter(String::isNotBlank).joinToString(" · ") else row.subtitle)
        views.setTextColor(R.id.widget_row_subtitle, colors.mutedForAppearanceInt(darkColors))
        if (!compact) {
            views.setTextViewText(R.id.widget_row_detail, row.detail)
            views.setTextColor(R.id.widget_row_detail, colors.mutedForAppearanceInt(darkColors))
            views.setTextColor(R.id.widget_row_subtitle, colors.mutedForAppearanceInt(darkColors))
            views.setInt(
                R.id.widget_row_root,
                "setBackgroundResource",
                if (row.highlighted) R.drawable.bg_widget_row_highlight else 0,
            )
        }
        views.setContentDescription(R.id.widget_row_root, listOf(row.title, row.subtitle, row.detail, row.trailing).filter(String::isNotBlank).joinToString(", "))
        views.setOnClickFillInIntent(
            R.id.widget_row_root,
            Intent().putExtra(DieterSyncService.EXTRA_CARD_ID, row.cardId),
        )
        return views
    }

    private fun iconRes(kind: WidgetRowKind): Int = when (kind) {
        WidgetRowKind.WAITING -> R.drawable.ic_widget_eye
        WidgetRowKind.RUNNING -> R.drawable.ic_widget_running
        WidgetRowKind.CHAT -> R.drawable.ic_widget_chat
        WidgetRowKind.FAILED -> R.drawable.ic_widget_error
        WidgetRowKind.REVIEW -> R.drawable.ic_widget_check
    }

    private fun iconColor(kind: WidgetRowKind): Int = when (kind) {
        WidgetRowKind.WAITING, WidgetRowKind.REVIEW -> if (darkColors) 0xFFE2BE6A.toInt() else 0xFF805500.toInt()
        WidgetRowKind.RUNNING -> colors.liveForAppearanceInt(darkColors)
        WidgetRowKind.FAILED -> if (darkColors) 0xFFF1868E.toInt() else 0xFFBA1A1A.toInt()
        WidgetRowKind.CHAT -> colors.mutedForAppearanceInt(darkColors)
    }

    private fun iconBgRes(kind: WidgetRowKind): Int = when (kind) {
        WidgetRowKind.WAITING, WidgetRowKind.REVIEW -> if (darkColors) palette.widgetIconBackground() else R.drawable.bg_widget_icon_amber
        WidgetRowKind.RUNNING -> palette.widgetIconBackground()
        WidgetRowKind.FAILED -> if (darkColors) palette.widgetIconBackground() else R.drawable.bg_widget_icon_coral
        WidgetRowKind.CHAT -> palette.widgetIconBackground()
    }

    private fun trailingColor(kind: WidgetRowKind): Int = when (kind) {
        WidgetRowKind.WAITING, WidgetRowKind.REVIEW -> if (darkColors) 0xFFE2BE6A.toInt() else 0xFF805500.toInt()
        WidgetRowKind.RUNNING -> colors.liveForAppearanceInt(darkColors)
        WidgetRowKind.FAILED -> if (darkColors) 0xFFF1868E.toInt() else 0xFFBA1A1A.toInt()
        else -> colors.mutedForAppearanceInt(darkColors)
    }

}
