package com.dbpprt.dieter.connection

import org.junit.Assert.assertEquals
import org.junit.Test

class ResultSummaryPolicyTest {
    @Test
    fun singleResultCancelsTheRedundantSummary() {
        assertEquals(
            ResultSummaryAction.CANCEL,
            resultSummaryAction(
                activeChildIds = setOf(41),
                summarizedChildIds = emptySet(),
                summaryActive = true,
            ),
        )
    }

    @Test
    fun singleResultWithoutASummaryStaysUnchanged() {
        assertEquals(
            ResultSummaryAction.UNCHANGED,
            resultSummaryAction(
                activeChildIds = setOf(41),
                summarizedChildIds = emptySet(),
                summaryActive = false,
            ),
        )
    }

    @Test
    fun multipleResultsPostOneSummary() {
        assertEquals(
            ResultSummaryAction.POST,
            resultSummaryAction(
                activeChildIds = setOf(41, 42),
                summarizedChildIds = emptySet(),
                summaryActive = false,
            ),
        )
    }

    @Test
    fun unchangedResultsDoNotRepostTheSummary() {
        val children = setOf(41, 42)

        assertEquals(
            ResultSummaryAction.UNCHANGED,
            resultSummaryAction(
                activeChildIds = children,
                summarizedChildIds = children,
                summaryActive = true,
            ),
        )
    }

    @Test
    fun dismissedChildRefreshesTheSummaryOnce() {
        assertEquals(
            ResultSummaryAction.POST,
            resultSummaryAction(
                activeChildIds = setOf(42, 43),
                summarizedChildIds = setOf(41, 42, 43),
                summaryActive = true,
            ),
        )
    }

    @Test
    fun clearedSummaryBookkeepingIsResetOnce() {
        assertEquals(
            ResultSummaryAction.CANCEL,
            resultSummaryAction(
                activeChildIds = emptySet(),
                summarizedChildIds = setOf(41, 42),
                summaryActive = false,
            ),
        )
    }
}
