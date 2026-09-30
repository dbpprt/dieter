package com.dbpprt.dieter.core

import com.dbpprt.dieter.core.connection.ConnectionPhase
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
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import okio.Path.Companion.toOkioPath

/** Drives the whole runtime against a disposable gateway and daemons. */
class CoreRuntimeEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun connectsOverTheRelayAndSyncsTheAttachedMachine() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)

        val connected = runtime.connection.state.await(describe = { "connected: ${runtime.connection.state.value}" }) {
            it.phase == ConnectionPhase.CONNECTED
        }
        assertEquals(fixture.daemonId, connected.attachedMachineId)
        val view = runtime.workspace.state.await(describe = { "project ${fixture.projectId}" }) { it.project(fixture.projectId) != null }
        assertNotNull(view.board(fixture.boardId))
        assertEquals(RouteKind.RELAY, runtime.sessions.routes.value[fixture.daemonId]?.kind)

        val machines = runtime.connection.machines.value
        assertTrue(machines.online.any { it.id == fixture.daemonId })
        val incompatible = assertNotNull(machines.machine(fixture.incompatibleDaemonId))
        assertFalse(incompatible.compatible && incompatible.online(machines.evaluatedAt))

        val health = runtime.onMachine(fixture.daemonId) { it.Health().execute(Unit) }
        assertEquals("ok", health.status, "health: $health")
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
                            val call = client.WatchSync()
                            val frames = call.executeIn(this, com.dbpprt.dieter.api.v1.SyncRequest(heartbeat_ms = 1000))
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
        runtime.connection.state.await(describe = { "connected: ${runtime.connection.state.value}" }) { it.phase == ConnectionPhase.CONNECTED }
        assertEquals(RouteKind.LOCAL, runtime.sessions.routes.value[fixture.daemonId]?.kind)
        runtime.workspace.state.await { it.project(fixture.projectId) != null }
    }

    @Test
    fun fallsBackToTheRelayWhenTheDirectRouteRefuses() = e2e {
        val fixture = fixture(directRoute = "dead")
        val runtime = runtime(fixture)
        runtime.connection.state.await(describe = { "connected: ${runtime.connection.state.value}" }) { it.phase == ConnectionPhase.CONNECTED }
        assertEquals(RouteKind.RELAY, runtime.sessions.routes.value[fixture.daemonId]?.kind)
    }

    @Test
    fun rendersTheCachedProjectionBeforeAnyNetworkAccess() = e2e {
        val fixture = fixture()
        val directory = Files.createTempDirectory("dieter-core-cache").toOkioPath()
        val secrets = MemorySecureStore()
        val first = runtime(fixture, jvmTestPlatform(directory, secrets))
        first.workspace.state.await { it.project(fixture.projectId) != null }
        first.shutdown()
        runtimes -= first

        fixture.daemonOffline()
        val second = runtime(fixture, jvmTestPlatform(directory, secrets), active = false)
        val cached = second.workspace.state.await(describe = { "cached projection" }) { it.loaded }
        assertNotNull(cached.project(fixture.projectId))
        assertNotNull(cached.board(fixture.boardId))
        assertEquals(ConnectionPhase.DISCONNECTED, second.connection.state.await { it.gateway != null }.phase)
    }

    @Test
    fun waitsForAMachineWhileTheOnlyDaemonIsOffline() = e2e {
        val fixture = fixture()
        fixture.daemonOffline()
        val runtime = runtime(fixture)
        runtime.connection.state.await(describe = { "no machine: ${runtime.connection.state.value}" }) { it.phase == ConnectionPhase.NO_MACHINE }
        fixture.daemonOnline()
        runtime.connection.state.await(timeout = kotlin.time.Duration.parse("45s"), describe = { "reconnected: ${runtime.connection.state.value}" }) {
            it.phase == ConnectionPhase.CONNECTED
        }
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
    fun otherMachinesArePolledWithoutMovingTheFeed() = e2e {
        val fixture = fixture(secondDaemon = true)
        val runtime = runtime(fixture)
        runtime.connection.state.await { it.phase == ConnectionPhase.CONNECTED }
        runtime.connection.freshness.await(describe = { "second machine refreshed: ${runtime.connection.freshness.value}" }) {
            it[fixture.secondDaemonId]?.refreshedAt != null
        }
        assertEquals(fixture.daemonId, runtime.connection.state.value.attachedMachineId)
        assertEquals(fixture.daemonId, runtime.connection.feedStatus.value.daemonId)
        // Reaching the second machine uses its own scoped plane.
        runtime.onMachine(fixture.secondDaemonId) { it.Health().execute(Unit) }
        assertEquals(setOf(fixture.daemonId, fixture.secondDaemonId), runtime.sessions.routes.value.keys)
    }
}
