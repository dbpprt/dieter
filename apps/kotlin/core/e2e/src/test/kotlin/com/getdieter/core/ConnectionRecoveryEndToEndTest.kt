package com.getdieter.core

import com.getdieter.client.v1.Command
import com.getdieter.client.v1.SetConnected
import com.getdieter.client.v1.SystemWoke
import com.getdieter.core.client.ClientApi
import com.getdieter.core.connection.ConnectionPhase
import com.getdieter.core.connection.SyncState
import com.getdieter.core.testing.ConnectionPerChannelTransport
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.IsolatedGateway
import com.getdieter.core.testing.SharedGateway
import com.getdieter.core.testing.StallingProxy
import com.getdieter.core.testing.await
import com.getdieter.core.testing.jvmTestPlatform
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import org.junit.AfterClass

/**
 * After a Mac sleeps and wakes, the connections it had open can lead nowhere without ever failing.
 * The core replaces them on its own once its watchdogs notice, and at once when the app reports the
 * wake.
 */
class ConnectionRecoveryEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    private suspend fun connect(fixture: IsolatedGateway, proxy: StallingProxy): CoreRuntime {
        val runtime =
            runtime(
                fixture,
                platform = jvmTestPlatform(transport = ConnectionPerChannelTransport()),
                gatewayUrl = proxy.url,
            )
        runtime.awaitConnected()
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
        return runtime
    }

    @Test
    fun silentConnectionsAreReplacedWithoutAnyFailure() = e2e {
        val fixture = shared.acquire()
        StallingProxy(fixture.address).use { proxy ->
            val runtime = connect(fixture, proxy)
            val silent = runtime.connection.session.value
            proxy.stall()
            // The machine's silent stream turns its view stale first; the silent presence stream
            // then ends the session, and the next one connects afresh.
            runtime.awaitSync(fixture.daemonId, SyncState.STALE)
            runtime.connection.session.await(
                60.seconds,
                describe = { "a new session: ${runtime.connection.state.value}" },
            ) {
                it != null && it !== silent
            }
            runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
            assertTrue(runtime.connection.machines.value.online.any { it.id == fixture.daemonId })
        }
    }

    @Test
    fun aWakeReopensSilentConnectionsAtOnce() = e2e {
        val fixture = shared.acquire()
        StallingProxy(fixture.address).use { proxy ->
            val runtime = connect(fixture, proxy)
            val silent = runtime.connection.session.value
            proxy.stall()
            ClientApi(runtime).dispatch(Command(system_woke = SystemWoke()))
            // Well before the silent stream would have turned the machine's view stale.
            runtime.connection.session.await(
                10.seconds,
                describe = { "a new session: ${runtime.connection.state.value}" },
            ) {
                it != null && it !== silent
            }
            runtime.connection.syncs.await(
                10.seconds,
                describe = { "current: ${runtime.connection.syncs.value[fixture.daemonId]}" },
            ) {
                it[fixture.daemonId]?.current == true
            }
        }
    }

    @Test
    fun aWakeKeepsADisconnect() = e2e {
        val fixture = shared.acquire()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val api = ClientApi(runtime)
        api.dispatch(Command(set_connected = SetConnected(connected = false)))
        runtime.connection.state.await(30.seconds) { it.phase == ConnectionPhase.DISCONNECTED }
        api.dispatch(Command(system_woke = SystemWoke()))
        delay(2.seconds)
        assertEquals(ConnectionPhase.DISCONNECTED, runtime.connection.state.value.phase)
        assertEquals(null, runtime.connection.session.value)
    }

    companion object {
        private val shared = SharedGateway()

        @JvmStatic @AfterClass fun closeFixture() = shared.close()
    }
}
