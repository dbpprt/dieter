package com.dbpprt.dieter.ui

internal fun shouldFollowConversationUpdate(
    explicitOpenScroll: Boolean,
    initialScrollComplete: Boolean,
    followingLatest: Boolean,
    isAtLatestAfterUpdate: Boolean,
): Boolean = explicitOpenScroll || !initialScrollComplete || (followingLatest && isAtLatestAfterUpdate)

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
