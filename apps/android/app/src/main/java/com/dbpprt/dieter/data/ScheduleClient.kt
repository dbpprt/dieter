package com.dbpprt.dieter.data

import com.dbpprt.dieter.v1.*
import java.util.concurrent.TimeUnit

interface ScheduleClient {
    suspend fun details(id: String): Schedule
    suspend fun list(project: String, pageToken: String = ""): SchedulesResponse
    suspend fun preview(cron: String, timezone: String): SchedulePreview
    suspend fun save(id: String, request: SaveScheduleRequest): Schedule
    suspend fun run(id: String): ScheduleRun
    suspend fun enabled(id: String, enabled: Boolean): Schedule
    suspend fun runs(id: String, pageToken: String = ""): ScheduleRunsResponse
    suspend fun delete(id: String)
}

internal class GrpcScheduleClient(private val route: DieterServiceGrpcKt.DieterServiceCoroutineStub) : ScheduleClient {
    private fun unary() = route.withDeadlineAfter(15, TimeUnit.SECONDS)
    private fun ref(id: String) = ScheduleRef.newBuilder().setScheduleId(id).build()
    override suspend fun details(id: String) = unary().getSchedule(ref(id))
    override suspend fun list(project: String, pageToken: String) = unary().listSchedules(
        ListSchedulesRequest.newBuilder().setProjectId(project).setPageSize(50).setPageToken(pageToken).build(),
    )
    override suspend fun preview(cron: String, timezone: String) = unary().previewSchedule(
        PreviewScheduleRequest.newBuilder().setCron(cron).setTimezone(timezone).setCount(5).build(),
    )
    override suspend fun save(id: String, request: SaveScheduleRequest): Schedule {
        val input = request.toBuilder().setScheduleId(id).build()
        return if (id.isBlank()) unary().createSchedule(input) else unary().updateSchedule(input)
    }
    override suspend fun run(id: String) = unary().runSchedule(ref(id))
    override suspend fun enabled(id: String, enabled: Boolean) = unary().setScheduleEnabled(
        SetScheduleEnabledRequest.newBuilder().setScheduleId(id).setEnabled(enabled).build(),
    )
    override suspend fun runs(id: String, pageToken: String) = unary().listScheduleRuns(
        ListScheduleRunsRequest.newBuilder().setScheduleId(id).setPageSize(50).setPageToken(pageToken).build(),
    )
    override suspend fun delete(id: String) { unary().deleteSchedule(ref(id)) }
}
