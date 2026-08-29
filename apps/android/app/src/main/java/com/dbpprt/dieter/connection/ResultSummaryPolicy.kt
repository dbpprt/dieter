package com.dbpprt.dieter.connection

internal enum class ResultSummaryAction {
    UNCHANGED,
    CANCEL,
    POST,
}

/**
 * A single result is already a complete notification and must not gain a
 * second, empty group-summary row. Multiple results share one summary, which
 * is updated only when the visible children actually change.
 */
internal fun resultSummaryAction(
    activeChildIds: Set<Int>,
    summarizedChildIds: Set<Int>,
    summaryActive: Boolean,
): ResultSummaryAction = when {
    activeChildIds.size < 2 && (summaryActive || summarizedChildIds.isNotEmpty()) -> ResultSummaryAction.CANCEL
    activeChildIds.size < 2 -> ResultSummaryAction.UNCHANGED
    !summaryActive || activeChildIds != summarizedChildIds -> ResultSummaryAction.POST
    else -> ResultSummaryAction.UNCHANGED
}
