package com.getdieter.mobile.store

import kotlinx.coroutines.flow.MutableStateFlow

/** Layout choices this device keeps: where the list and detail panes divide. */
class LayoutModel internal constructor(private val preferences: MobilePreferences) {
    /** The list pane's share of a two-pane window; see [PaneSplit]. */
    val paneFraction =
        MutableStateFlow(
            preferences.read("pane-fraction")?.toFloatOrNull()?.takeIf { it in 0f..1f }
                ?: PaneSplit.DEFAULT_FRACTION
        )

    fun setPaneFraction(value: Float) {
        paneFraction.value = value.coerceIn(0f, 1f)
        preferences.write("pane-fraction", paneFraction.value.toString())
    }
}

/** How a two-pane window divides: the list keeps a readable width, and so does the detail. */
object PaneSplit {
    const val DEFAULT_FRACTION = .42f
    const val MIN_LIST_DP = 280f
    const val MIN_DETAIL_DP = 320f

    /** The list pane's width in dp for a window [total] dp wide. */
    fun listWidth(total: Float, fraction: Float): Float {
        val widest = (total - MIN_DETAIL_DP).coerceAtLeast(MIN_LIST_DP)
        return (total * fraction).coerceIn(MIN_LIST_DP, widest)
    }

    /** The fraction a list [width] dp wide in a window [total] dp wide stands for. */
    fun fraction(total: Float, width: Float): Float =
        if (total <= 0f) DEFAULT_FRACTION else listWidth(total, width / total) / total
}
