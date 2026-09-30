package com.dbpprt.dieter.core.board

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LanesTest {
    @Test
    fun laneRolesMatchTheirIdsAndReviewLanesByName() {
        for (lane in listOf("review", "Review", "In review", "needs-review")) assertTrue(Lanes.isReview(lane), lane)
        assertFalse(Lanes.isReview("todo"))
        assertTrue(Lanes.isRunning("Running"))
        assertFalse(Lanes.isRunning("running-late"))
        assertTrue(Lanes.isDone("DONE"))
        assertFalse(Lanes.isDone("undone"))
    }
}
