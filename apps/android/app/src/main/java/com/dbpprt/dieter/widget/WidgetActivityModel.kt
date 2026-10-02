package com.dbpprt.dieter.widget

import com.dbpprt.dieter.core.activity.WidgetModel
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

// LAST_FINISHED is a persisted style identifier. All styles show the same
// Inbox; this option only chooses a compact presentation.
enum class WidgetStyle { AUTO, ACTIVITY, LAST_FINISHED }

data class WidgetConfig(
    val style: WidgetStyle = WidgetStyle.AUTO,
    val maxItems: Int = DEFAULT_MAX_ITEMS,
    val showSections: Boolean = true,
) {
    companion object {
        const val DEFAULT_MAX_ITEMS = 12
        val MAX_ITEM_CHOICES = listOf(6, 12, 20)
    }
}

/** The widget's style as the core's; LAST_FINISHED is a persisted identifier for the compact style. */
internal val WidgetStyle.core: WidgetModel.Style
    get() = when (this) {
        WidgetStyle.AUTO -> WidgetModel.Style.AUTO
        WidgetStyle.ACTIVITY -> WidgetModel.Style.ACTIVITY
        WidgetStyle.LAST_FINISHED -> WidgetModel.Style.COMPACT
    }

/**
 * A widget's last update as an absolute local time ("Sep 26, 10:00"), which
 * stays truthful across hours of host suspension; null before the first one.
 */
internal fun widgetTime(epochMs: Long): String? = epochMs.takeIf { it > 0 }?.let {
    DateTimeFormatter.ofPattern("MMM d, HH:mm").withZone(ZoneId.systemDefault()).format(Instant.ofEpochMilli(it))
}
