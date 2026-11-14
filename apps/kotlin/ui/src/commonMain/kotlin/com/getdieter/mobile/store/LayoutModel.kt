package com.getdieter.mobile.store

import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Which shell this device shows. [AUTOMATIC] follows the window: Samsung DeX, Android desktop
 * windowing and connected displays get the desktop shell, phones and tablets the touch one.
 */
enum class InterfaceMode(val title: String) {
    AUTOMATIC("Automatic"),
    DESKTOP("Desktop"),
    TOUCH("Touch"),
}

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

    val interfaceMode =
        MutableStateFlow(
            preferences.read("interface")?.let { value ->
                InterfaceMode.entries.firstOrNull { it.name == value }
            } ?: InterfaceMode.AUTOMATIC
        )

    /** The desktop sidebar is hidden; the window keeps a button that shows it again. */
    val sidebarHidden = MutableStateFlow(preferences.read("desktop-sidebar-hidden") == "true")

    /** Widths the desktop shell's dividers were dragged to, in dp, by pane; see [DesktopPane]. */
    val desktopWidths =
        MutableStateFlow(
            DesktopPane.entries.associateWith { pane ->
                preferences.read("desktop-width-${pane.key}")?.toFloatOrNull()?.let(pane::clamp)
                    ?: pane.default
            }
        )

    fun setInterfaceMode(value: InterfaceMode) {
        interfaceMode.value = value
        preferences.write("interface", value.name)
    }

    fun setSidebarHidden(value: Boolean) {
        sidebarHidden.value = value
        preferences.write("desktop-sidebar-hidden", value.toString())
    }

    fun setDesktopWidth(pane: DesktopPane, width: Float) {
        val value = pane.clamp(width)
        desktopWidths.value = desktopWidths.value + (pane to value)
        preferences.write("desktop-width-${pane.key}", value.toString())
    }

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

/** The desktop shell's resizable panes: their default, narrowest and widest widths in dp. */
enum class DesktopPane(val key: String, val default: Float, val min: Float, val max: Float) {
    SIDEBAR("sidebar", 248f, 220f, 310f),
    INBOX("inbox", 340f, 300f, 420f),
    CHATS("chats", 320f, 285f, 380f),
    MAIL("mail", 360f, 320f, 460f),
    CHANNELS("channels", 280f, 240f, 360f),
    TOOLS("tools", 340f, 280f, 440f),
    /** The conversation beside a board. */
    CONVERSATION("conversation", 520f, 360f, 1320f);

    fun clamp(width: Float) = width.coerceIn(min, max)
}

/** When the desktop shell shows, and how its window divides. */
object DesktopLayout {
    /** Narrower or lower windows get the touch shell, whatever the mode. */
    const val MIN_WIDTH_DP = 720f
    const val MIN_HEIGHT_DP = 420f

    /** Below this width the sidebar floats above the content instead of beside it. */
    const val SIDEBAR_BESIDE_DP = 1000f

    /** What a board keeps beside an open conversation. */
    const val MIN_BOARD_DP = 280f

    /**
     * The desktop shell shows for [mode] in a window [width] × [height] dp wide; [host] is the
     * platform's desktop signal (DeX, desktop windowing, an external display or a PC).
     */
    fun shows(mode: InterfaceMode, host: Boolean, width: Float, height: Float): Boolean =
        width >= MIN_WIDTH_DP &&
            height >= MIN_HEIGHT_DP &&
            when (mode) {
                InterfaceMode.AUTOMATIC -> host
                InterfaceMode.DESKTOP -> true
                InterfaceMode.TOUCH -> false
            }

    /** The conversation's width beside a board in a workspace [total] dp wide. */
    fun conversationWidth(total: Float, preferred: Float): Float =
        DesktopPane.CONVERSATION.clamp(preferred)
            .coerceAtMost((total - MIN_BOARD_DP).coerceAtLeast(DesktopPane.CONVERSATION.min))
            .coerceAtMost(total)

    /** Equal lanes filling [available] dp, each at least [minLane] wide, [gap] apart. */
    fun laneWidth(available: Float, lanes: Int, gap: Float = 9f, minLane: Float = 264f): Float =
        if (lanes <= 0) minLane
        else ((available - gap * (lanes - 1)) / lanes).coerceAtLeast(minLane)
}
