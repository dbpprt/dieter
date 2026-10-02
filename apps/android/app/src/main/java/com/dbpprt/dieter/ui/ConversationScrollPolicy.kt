package com.dbpprt.dieter.ui

internal fun shouldFollowConversationUpdate(
    explicitOpenScroll: Boolean,
    initialScrollComplete: Boolean,
    followingLatest: Boolean,
): Boolean = explicitOpenScroll || !initialScrollComplete || followingLatest

/**
 * The conversation list's rows in order: the history control, the unsent
 * task, the timeline, the working indicator, the turn-failure banner, the
 * queue, and the end marker.
 */
internal data class ConversationRows(
    val history: Boolean,
    val unsentTask: Boolean,
    val timelineItems: Int,
    val working: Boolean,
    val turnFailure: Boolean,
    val queued: Int,
) {
    /** The index of the first timeline row. */
    val timelineStart: Int get() = (if (history) 1 else 0) + (if (unsentTask) 1 else 0)

    /** The index of the end marker, after every other row; following the latest scrolls here. */
    val end: Int get() = timelineStart + timelineItems + (if (working) 1 else 0) + (if (turnFailure) 1 else 0) + queued
}

internal data class ConversationHistoryViewport(
    val firstVisibleItemIndex: Int,
    val canScrollBackward: Boolean,
    val canScrollForward: Boolean,
    val hasItems: Boolean,
) {
    val needsBackfill: Boolean
        get() = hasItems && !canScrollBackward && !canScrollForward
}

internal fun shouldLoadEarlierConversationHistory(
    hasMore: Boolean,
    loading: Boolean,
    anchorPending: Boolean,
    initialScrollComplete: Boolean,
    viewport: ConversationHistoryViewport,
): Boolean = hasMore &&
    !loading &&
    !anchorPending &&
    initialScrollComplete &&
    (viewport.firstVisibleItemIndex <= 3 || viewport.needsBackfill)
