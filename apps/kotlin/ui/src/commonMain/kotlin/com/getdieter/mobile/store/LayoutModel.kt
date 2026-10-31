package com.getdieter.mobile.store

import kotlinx.coroutines.flow.MutableStateFlow

/** Which pane of a two-pane window was dragged away. */
enum class PaneCollapse {
    NONE,
    /** The open page fills the window; with nothing open, the list shows beside the placeholder. */
    LIST,
    /** The list fills the window until something opens from it. */
    DETAIL,
}

/** Layout choices this device keeps: where the list and detail panes divide, or which is gone. */
class LayoutModel internal constructor(private val preferences: MobilePreferences) {
    /** The list pane's share of a two-pane window; see [PaneSplit]. */
    val paneFraction =
        MutableStateFlow(
            preferences.read("pane-fraction")?.toFloatOrNull()?.takeIf { it in 0f..1f }
                ?: PaneSplit.DEFAULT_FRACTION
        )

    val paneCollapse =
        MutableStateFlow(
            preferences.read("pane-collapse")?.let { value ->
                PaneCollapse.entries.firstOrNull { it.name == value }
            } ?: PaneCollapse.NONE
        )

    fun setPaneFraction(value: Float) {
        paneFraction.value = value.coerceIn(0f, 1f)
        preferences.write("pane-fraction", paneFraction.value.toString())
    }

    fun setPaneCollapse(value: PaneCollapse) {
        if (paneCollapse.value == value) return
        paneCollapse.value = value
        preferences.write("pane-collapse", value.name)
    }

    /** Ends a drag that left the list [width] dp wide in a window [total] dp wide. */
    fun settle(total: Float, width: Float) {
        val collapse = PaneSplit.collapse(total, width)
        if (collapse == PaneCollapse.NONE) setPaneFraction(PaneSplit.fraction(total, width))
        setPaneCollapse(collapse)
    }

    /** Both panes again, divided as by default. */
    fun resetPanes() {
        setPaneFraction(PaneSplit.DEFAULT_FRACTION)
        setPaneCollapse(PaneCollapse.NONE)
    }
}

/**
 * How a two-pane window divides: the list keeps a readable width, and so does the detail. A pane
 * dragged well below its minimum goes away, so the other one fills the window.
 */
object PaneSplit {
    const val DEFAULT_FRACTION = .42f
    const val MIN_LIST_DP = 280f
    const val MIN_DETAIL_DP = 320f

    /** A pane released narrower than this share of its minimum collapses. */
    const val COLLAPSE_SHARE = .6f

    /** The list pane's width in dp for a window [total] dp wide. */
    fun listWidth(total: Float, fraction: Float): Float {
        val widest = (total - MIN_DETAIL_DP).coerceAtLeast(MIN_LIST_DP)
        return (total * fraction).coerceIn(MIN_LIST_DP, widest)
    }

    /** The fraction a list [width] dp wide in a window [total] dp wide stands for. */
    fun fraction(total: Float, width: Float): Float =
        if (total <= 0f) DEFAULT_FRACTION else listWidth(total, width / total) / total

    /** The pane a drag released with the list [width] dp wide collapses, if any. */
    fun collapse(total: Float, width: Float): PaneCollapse =
        when {
            width < MIN_LIST_DP * COLLAPSE_SHARE -> PaneCollapse.LIST
            total - width < MIN_DETAIL_DP * COLLAPSE_SHARE -> PaneCollapse.DETAIL
            else -> PaneCollapse.NONE
        }

    /** The list's width in dp as [collapse] and [fraction] show it. */
    fun shownWidth(total: Float, fraction: Float, collapse: PaneCollapse): Float =
        when (collapse) {
            PaneCollapse.LIST -> 0f
            PaneCollapse.DETAIL -> total
            PaneCollapse.NONE -> listWidth(total, fraction)
        }
}
