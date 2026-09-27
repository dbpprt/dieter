package com.dbpprt.dieter.ui

import com.dbpprt.dieter.data.AdministrationClient
import com.dbpprt.dieter.data.ScheduleClient
import com.dbpprt.dieter.v1.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class FeatureControllerTest {
    private open class Schedules : ScheduleClient {
        override suspend fun details(id: String): Schedule = error("unused")
        override suspend fun list(project: String, pageToken: String): SchedulesResponse = error("unused")
        override suspend fun preview(cron: String, timezone: String): SchedulePreview = error("unused")
        override suspend fun save(id: String, request: SaveScheduleRequest): Schedule = error("unused")
        override suspend fun run(id: String): ScheduleRun = error("unused")
        override suspend fun enabled(id: String, enabled: Boolean): Schedule = error("unused")
        override suspend fun runs(id: String, pageToken: String): ScheduleRunsResponse = error("unused")
        override suspend fun delete(id: String) = Unit
    }
    @Test fun latestPreviewSurvivesLateSuccessAndSurfaceClosure() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val errors = mutableListOf<Throwable>()
        val client = object : Schedules() {
            override suspend fun preview(cron: String, timezone: String): SchedulePreview {
                if (cron == "old") withContext(NonCancellable) { release.await() }
                return SchedulePreview.newBuilder().addTimes(cron).build()
            }
        }
        val owner = ScheduleController(this, { "project" }, { client }, { client }, { client to "checkout" }, {}, errors::add)
        owner.preview("project", "old", "UTC")
        yield()
        owner.preview("project", "latest", "UTC").join()
        assertEquals(listOf("latest"), owner.state.schedulePreview)
        owner.clearPreview()
        release.complete(Unit)
        yield()
        assertTrue(owner.state.schedulePreview.isEmpty())
        assertTrue(errors.isEmpty())
    }

    @Test fun routePreparationCannotDispatchForARetiredBinding() = runBlocking {
        var binding = "old"
        val release = CompletableDeferred<Unit>()
        var dispatched = false
        val client = object : Schedules() {
            override suspend fun list(project: String, pageToken: String): SchedulesResponse {
                dispatched = true
                return SchedulesResponse.getDefaultInstance()
            }
        }
        val owner = ScheduleController(this, { binding }, { withContext(NonCancellable) { release.await() }; client },
            { client }, { client to "checkout" }, {}, { throw AssertionError(it) })
        owner.load("old")
        yield()
        owner.reset()
        binding = "new"
        release.complete(Unit)
        yield()
        assertFalse(dispatched)
        assertFalse(owner.state.schedulesLoading)
    }

    @Test fun administrationUsesOneCapturedBoardAndRejectsLateSnapshot() = runBlocking {
        var binding = "old-board"
        val release = CompletableDeferred<Unit>()
        val boards = mutableListOf<String>()
        val errors = mutableListOf<Throwable>()
        val client = object : AdministrationClient {
            override suspend fun settings(): Settings {
                withContext(NonCancellable) { release.await() }
                return Settings.getDefaultInstance()
            }
            override suspend fun options() = SettingsOptions.getDefaultInstance()
            override suspend fun archivedProjects() = ProjectsResponse.getDefaultInstance()
            override suspend fun archivedCards(board: String): CardsResponse {
                boards.add(board)
                return CardsResponse.newBuilder().addCards(Card.newBuilder().setId(board)).build()
            }
            override suspend fun update(settings: Settings) = settings
        }
        val owner = AdministrationController(this, { binding }, { client }, {}, errors::add)
        owner.load("project", binding)
        yield(); yield()
        binding = "new-board"
        owner.reset()
        release.complete(Unit)
        yield(); yield()
        assertEquals(listOf("old-board"), boards)
        assertTrue(owner.state.archivedCards.isEmpty())
        assertNull(owner.state.settings)
        assertTrue(errors.isEmpty())
    }
}
