package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.v1.ScheduleRun
import com.dbpprt.dieter.v1.ScheduleRunsResponse
import com.dbpprt.dieter.v1.SchedulesResponse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SchedulePaginationPolicyTest {
    @Test
    fun `schedule pages append without duplicates and retain the server cursor`() {
        val first = Schedule.newBuilder().setId("s_first").build()
        val second = Schedule.newBuilder().setId("s_second").build()
        val initial = DieterUiState(schedulesLoading = true).applyingSchedulePage(
            SchedulesResponse.newBuilder()
                .addSchedules(first)
                .setTotalCount(2)
                .setNextPageToken("next")
                .build(),
            appending = false,
        )
        val complete = initial.copy(schedulesLoadingMore = true).applyingSchedulePage(
            SchedulesResponse.newBuilder()
                .addSchedules(first)
                .addSchedules(second)
                .setTotalCount(2)
                .build(),
            appending = true,
        )

        assertEquals(listOf(first.id, second.id), complete.schedules.map { it.id })
        assertEquals(2, complete.schedulesTotalCount)
        assertEquals("", complete.schedulesNextPageToken)
        assertFalse(complete.schedulesLoading)
        assertFalse(complete.schedulesLoadingMore)
    }

    @Test
    fun `occurrence pages keep newest first and deduplicate page boundaries`() {
        val newest = ScheduleRun.newBuilder().setId("sr_new").build()
        val older = ScheduleRun.newBuilder().setId("sr_old").build()
        val initial = DieterUiState(scheduleRunsLoading = true).applyingScheduleRunPage(
            ScheduleRunsResponse.newBuilder().addRuns(newest).setNextPageToken("older").build(),
            appending = false,
        )
        val complete = initial.copy(scheduleRunsLoadingMore = true).applyingScheduleRunPage(
            ScheduleRunsResponse.newBuilder().addRuns(newest).addRuns(older).build(),
            appending = true,
        )

        assertEquals(listOf(newest.id, older.id), complete.scheduleRuns.map { it.id })
        assertEquals("", complete.scheduleRunsNextPageToken)
        assertFalse(complete.scheduleRunsLoading)
        assertFalse(complete.scheduleRunsLoadingMore)
    }
}
