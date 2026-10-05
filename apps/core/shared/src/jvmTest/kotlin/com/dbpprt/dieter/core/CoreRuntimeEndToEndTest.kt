package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.ChangesRequest
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.connection.SyncState
import com.dbpprt.dieter.core.routing.RouteKind
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.MemorySecureStore
import com.dbpprt.dieter.core.testing.await
import com.dbpprt.dieter.core.testing.jvmTestPlatform
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Clock
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okio.Path.Companion.toOkioPath

/** Drives the whole runtime against a disposable gateway and daemons. */
class CoreRuntimeEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun connectsOverTheRelayAndStreamsEveryCompatibleMachine() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)

        runtime.awaitConnected()
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
        val view = runtime.awaitLoaded(fixture)
        assertNotNull(view.board(fixture.boardId))
        assertEquals(RouteKind.RELAY, runtime.sessions.routes.value[fixture.daemonId]?.kind)

        val machines = runtime.connection.machines.value
        assertTrue(machines.online.any { it.id == fixture.daemonId })
        val incompatible = assertNotNull(machines.machine(fixture.incompatibleDaemonId))
        assertFalse(incompatible.compatible && incompatible.online(machines.evaluatedAt))
        assertEquals(SyncState.INCOMPATIBLE, runtime.connection.syncs.value[fixture.incompatibleDaemonId]?.state)

        val health = runtime.onMachine(fixture.daemonId) { it.Health().execute(Unit) }
        assertEquals("ok", health.status, "health: $health")
    }

    @Test
    fun aChangeOnAMachineShowsWithoutAnyRequest() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitLoaded(fixture)
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
        // Another client creates a chat directly on the machine; this runtime only listens.
        val created = runtime.onMachine(fixture.daemonId) {
            it.CreateChat().execute(CreateConversationRequest(project_id = fixture.projectId, title = "Made elsewhere", prompt = "p", defer_start = true, workspace_mode = "project"))
        }
        val view = runtime.workspace.state.await(describe = { "chat ${created.id}" }) { it.card(created.id) != null }
        assertEquals("Made elsewhere", view.card(created.id)?.title)
        assertEquals("p", view.card(created.id)?.initial_prompt, "the owner's details arrive with it")
    }

    @Test
    fun everyMachineStreamsItsOwnPartOfTheAccountView() = e2e {
        val fixture = fixture(secondDaemon = true)
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
        runtime.awaitSync(fixture.secondDaemonId, SyncState.LIVE)

        // A project only the second machine holds joins the same view, streamed from that machine.
        val repository = Files.createTempDirectory("dieter-second-project").toFile().canonicalFile
        assertEquals(0, ProcessBuilder("git", "init", "-q", repository.path).start().waitFor())
        val created = assertNotNull(runtime.admin.createProject(fixture.secondDaemonId, repository.path, name = "Second machine").project)
        val both = runtime.workspace.state.await(describe = { "both projects: ${runtime.workspace.state.value.projects.map { it.name }}" }) {
            it.project(created.id)?.checkouts?.isNotEmpty() == true && it.project(fixture.projectId) != null
        }
        assertEquals(fixture.secondDaemonId, both.project(created.id)!!.checkouts.single().daemon_id)
        assertEquals(repository.path, both.project(created.id)!!.checkouts.single().path, "its owner streams the checkout's path")
        assertEquals(setOf(fixture.daemonId, fixture.secondDaemonId), runtime.sessions.routes.value.keys)

        val chat = runtime.onMachine(fixture.daemonId) {
            it.CreateChat().execute(CreateConversationRequest(project_id = fixture.projectId, title = "On the first machine", prompt = "p", defer_start = true, workspace_mode = "project"))
        }
        val shown = runtime.workspace.state.await { it.card(chat.id) != null }.card(chat.id)!!
        assertNull(runtime.staleness(shown, runtime.connection.syncs.value, runtime.connection.machines.value))

        // One machine going offline only makes its own cards stale.
        fixture.daemonOffline()
        runtime.awaitSync(fixture.daemonId, SyncState.OFFLINE)
        val name = runtime.connection.machines.value.machine(fixture.daemonId)!!.name
        assertEquals("$name is offline", runtime.staleness(shown, runtime.connection.syncs.value, runtime.connection.machines.value))
        assertEquals(SyncState.LIVE, runtime.connection.syncs.value[fixture.secondDaemonId]?.state)
        assertNotNull(runtime.workspace.state.value.card(chat.id), "its cached view stays")
        assertEquals(ConnectionPhase.CONNECTED, runtime.connection.state.value.phase)

        fixture.daemonOnline()
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE, 45.seconds)
    }

    @Test
    fun openingAConversationNeverReconnects() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitLoaded(fixture)
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
        val chat = runtime.onMachine(fixture.daemonId) {
            it.CreateChat().execute(CreateConversationRequest(project_id = fixture.projectId, title = "Open me", prompt = "p", defer_start = true, workspace_mode = "project"))
        }
        runtime.workspace.state.await { it.card(chat.id) != null }
        val phases = mutableListOf<ConnectionPhase>()
        val states = mutableListOf<SyncState?>()
        val watcher = launch {
            launch { runtime.connection.state.collect { phases += it.phase } }
            runtime.connection.syncs.collect { states += it[fixture.daemonId]?.state }
        }
        val session = runtime.openConversation(chat.id)
        session.view.await(describe = { "conversation: ${session.view.value}" }) { !it.loading }
        runtime.closeConversation(chat.id)
        delay(500)
        watcher.cancel()
        assertEquals(listOf(ConnectionPhase.CONNECTED), phases.distinct())
        assertEquals(listOf<SyncState?>(SyncState.LIVE), states.distinct())
    }

    @Test
    fun presenceHoldsSteadyWhateverTheDeviceClock() = e2e {
        val fixture = fixture()
        // A phone slightly behind the gateway, and one far ahead of it.
        for (skew in listOf((-250).milliseconds, 10.minutes)) {
            val clock = object : Clock {
                override fun now() = Clock.System.now() + skew
            }
            val runtime = runtime(fixture, jvmTestPlatform(clock = clock))
            runtime.awaitConnected()
            // The relayed daemon heartbeats every few seconds; each heartbeat pushes a freshly stamped report.
            val reports = mutableListOf<Pair<String, Boolean>>()
            withTimeoutOrNull(20.seconds) {
                runtime.connection.machines.first { directory ->
                    val machine = directory.machine(fixture.daemonId) ?: return@first false
                    reports += machine.lastSeenAt to machine.online(directory.evaluatedAt)
                    reports.map { it.first }.distinct().size >= 3
                }
            }
            assertTrue(reports.map { it.first }.distinct().size >= 3, "skew $skew saw no fresh heartbeats: $reports")
            assertTrue(reports.all { it.second }, "skew $skew flapped: $reports")
            assertEquals(ConnectionPhase.CONNECTED, runtime.connection.state.value.phase)
        }
    }

    @Test
    fun manyOpenStreamsNeverStarveAUnaryCall() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val streams = List(12) {
            launch {
                runCatching {
                    runtime.onMachine(fixture.daemonId) { client ->
                        coroutineScope {
                            val call = client.WatchChanges()
                            val frames = call.executeIn(this, ChangesRequest(heartbeat_ms = 1000))
                            try { for (frame in frames) Unit } finally { call.cancel() }
                        }
                    }
                }
            }
        }
        delay(1000)
        val health = withTimeout(5.seconds) { runtime.onMachine(fixture.daemonId) { it.Health().execute(Unit) } }
        assertEquals("ok", health.status)
        streams.forEach { it.cancel() }
    }

    @Test
    fun prefersThePinnedDirectRoute() = e2e {
        val fixture = fixture(directRoute = "live")
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        assertEquals(RouteKind.LOCAL, runtime.sessions.routes.value[fixture.daemonId]?.kind)
        assertEquals(fixture.daemonId, runtime.choice.local(), "a loopback route is this device's machine")
    }

    @Test
    fun fallsBackToTheRelayWhenTheDirectRouteRefuses() = e2e {
        val fixture = fixture(directRoute = "dead")
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
        assertEquals(RouteKind.RELAY, runtime.sessions.routes.value[fixture.daemonId]?.kind)
    }

    @Test
    fun rendersTheCachedViewBeforeAnyNetworkAccess() = e2e {
        val fixture = fixture()
        val directory = Files.createTempDirectory("dieter-core-cache").toOkioPath()
        val secrets = MemorySecureStore()
        val first = runtime(fixture, jvmTestPlatform(directory, secrets))
        first.awaitLoaded(fixture)
        val updated = assertNotNull(first.accountSync.updatedAt.value[fixture.daemonId]).toEpochMilliseconds()
        first.shutdown()
        runtimes -= first

        fixture.daemonOffline()
        // A restarted process that does not connect (a widget render after process death) shows the cached view and when it last changed.
        val second = runtime(fixture, jvmTestPlatform(directory, secrets), active = false)
        val cached = second.workspace.state.await(describe = { "cached view" }) { it.loaded }
        assertNotNull(cached.project(fixture.projectId))
        assertNotNull(cached.board(fixture.boardId))
        assertEquals(updated, second.accountSync.updatedAt.value[fixture.daemonId]?.toEpochMilliseconds())
        assertEquals(ConnectionPhase.DISCONNECTED, second.connection.state.await { it.gateway != null }.phase)
    }

    @Test
    fun anOfflineMachineCatchesUpWhenItReturns() = e2e {
        val fixture = fixture()
        fixture.daemonOffline()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitSync(fixture.daemonId, SyncState.OFFLINE)
        fixture.daemonOnline()
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE, 45.seconds)
        runtime.awaitLoaded(fixture)
    }

    @Test
    fun aRevokedSessionAsksForSignIn() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, token = "isolated_revoked")
        val state = runtime.connection.state.await(describe = { "auth required: ${runtime.connection.state.value}" }) {
            it.phase == ConnectionPhase.AUTH_REQUIRED
        }
        assertNotNull(state.error)
    }

    @Test
    fun missingCredentialsAskForSignIn() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, token = null)
        runtime.connection.state.await { it.phase == ConnectionPhase.AUTH_REQUIRED }
    }

    @Test
    fun anInvalidReleaseIsToldToUpdate() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, clientVersion = "not-a-release")
        runtime.connection.state.await(describe = { "update required: ${runtime.connection.state.value}" }) {
            it.phase == ConnectionPhase.UPDATE_REQUIRED
        }
    }

    @Test
    fun aWidgetRefreshConnectsBrieflyWithoutStayingOnline() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, active = false)
        assertTrue(runtime.connection.refreshForWidget(30.seconds))
        runtime.awaitLoaded(fixture)
        runtime.connection.state.await(20.seconds, describe = { "released: ${runtime.connection.state.value}" }) { it.phase == ConnectionPhase.DISCONNECTED }
    }
}
