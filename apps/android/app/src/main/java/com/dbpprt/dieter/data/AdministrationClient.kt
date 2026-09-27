package com.dbpprt.dieter.data

import com.dbpprt.dieter.v1.*
import com.google.protobuf.Empty
import java.util.concurrent.TimeUnit

interface AdministrationClient {
    suspend fun settings(): Settings
    suspend fun options(): SettingsOptions
    suspend fun archivedProjects(): ProjectsResponse
    suspend fun archivedCards(board: String): CardsResponse
    suspend fun update(settings: Settings): Settings
}

internal class GrpcAdministrationClient(private val route: DieterServiceGrpcKt.DieterServiceCoroutineStub) : AdministrationClient {
    private fun unary() = route.withDeadlineAfter(15, TimeUnit.SECONDS)
    override suspend fun settings() = unary().getSettings(Empty.getDefaultInstance())
    override suspend fun options() = unary().getSettingsOptions(Empty.getDefaultInstance())
    override suspend fun archivedProjects() = unary().listArchivedProjects(Empty.getDefaultInstance())
    override suspend fun archivedCards(board: String) = unary().listArchivedCards(BoardRef.newBuilder().setBoardId(board).build())
    override suspend fun update(settings: Settings) = unary().updateSettings(UpdateSettingsRequest.newBuilder().setSettings(settings).build())
}
