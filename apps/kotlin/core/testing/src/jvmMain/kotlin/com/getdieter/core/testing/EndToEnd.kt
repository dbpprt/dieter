package com.getdieter.core.testing

import com.getdieter.core.CoreRuntime
import com.getdieter.core.RuntimeConfig
import com.getdieter.core.connection.ConnectionPhase
import com.getdieter.core.connection.SyncState
import com.getdieter.core.identity.Gateway
import com.getdieter.core.platform.Platform
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking

/**
 * Owns the fixtures and runtimes of one end-to-end test and tears them down. Every runtime uses a
 * private state directory and the fixture's disposable credentials.
 */
open class EndToEnd {
    private val fixtures = mutableListOf<IsolatedGateway>()
    protected val runtimes = mutableListOf<CoreRuntime>()

    fun tearDownRuntimes() = runBlocking {
        runtimes.forEach { it.shutdown() }
        runtimes.clear()
        fixtures.forEach(IsolatedGateway::close)
        fixtures.clear()
    }

    fun e2e(block: suspend CoroutineScope.() -> Unit) = runBlocking { block() }

    fun fixture(directRoute: String? = null, secondDaemon: Boolean = false) =
        IsolatedGateway(directRoute, secondDaemon).also(fixtures::add)

    suspend fun runtime(
        fixture: IsolatedGateway,
        platform: Platform = jvmTestPlatform(),
        token: String? = fixture.token,
        clientVersion: String = RELEASE,
        active: Boolean = true,
        /** Where the runtime reaches [fixture], e.g. through a [StallingProxy]. */
        gatewayUrl: String = fixture.url,
        configure: (RuntimeConfig) -> RuntimeConfig = { it },
    ): CoreRuntime {
        val config =
            configure(
                RuntimeConfig(
                    clientVersion,
                    "dieter-test://oauth/callback",
                    includeLoopbackRoutes = true,
                    clientIdPrefix = "e2e",
                )
            )
        val runtime = CoreRuntime(platform, config)
        runtimes += runtime
        val gateway = requireNotNull(Gateway.parse(gatewayUrl))
        runtime.setGateways(listOf(gateway), gateway.origin)
        if (token != null) runtime.credentials.save(gateway, token)
        runtime.start()
        runtime.setActive(active)
        return runtime
    }

    suspend fun CoreRuntime.awaitConnected(timeout: Duration = 30.seconds) =
        connection.state.await(timeout, describe = { "connected: ${connection.state.value}" }) {
            it.phase == ConnectionPhase.CONNECTED
        }

    suspend fun CoreRuntime.awaitLoaded(fixture: IsolatedGateway) =
        workspace.state.await(describe = { "project ${fixture.projectId}" }) {
            it.project(fixture.projectId) != null
        }

    /**
     * Waits until the account view lists every card in [ids]. A created card shows from the outbox,
     * pending, before its machine's stream lists it, and operations on it need the listed card.
     */
    suspend fun CoreRuntime.awaitSynced(vararg ids: String, timeout: Duration = 30.seconds) =
        workspace.state.await(
            timeout,
            describe = {
                "synced ${ids.toList()}: pending ${workspace.state.value.pendingCardIds}"
            },
        ) { view ->
            ids.all { view.card(it) != null && it !in view.pendingCardIds }
        }

    /** Waits until [machineId]'s part of the account view is in [state]. */
    suspend fun CoreRuntime.awaitSync(
        machineId: String,
        state: SyncState,
        timeout: Duration = 30.seconds,
    ) =
        connection.syncs.await(
            timeout,
            describe = { "$machineId $state: ${connection.syncs.value[machineId]}" },
        ) {
            it[machineId]?.state == state
        }

    companion object {
        const val RELEASE = "0.0.0-dev.0"
    }
}

/**
 * The fixture gateway the tests of one class share, so a class pays for one launch and for one
 * first agent turn, which installs the harness runtime in the fixture's home. The first test that
 * asks starts it; the class's `@AfterClass` closes it. A test sharing it creates its own projects,
 * boards, cards, and terminals and asserts only on those, so it passes in any order; one that needs
 * another configuration, or would leave the fixture unusable, launches its own with
 * [EndToEnd.fixture]. A machine a failed test left offline is reconnected for the next test.
 */
class SharedGateway(
    private val directRoute: String? = null,
    private val secondDaemon: Boolean = false,
) : AutoCloseable {
    private var gateway: IsolatedGateway? = null

    /** The class's fixture, started on first use. */
    @Synchronized
    fun acquire(): IsolatedGateway =
        (gateway ?: IsolatedGateway(directRoute, secondDaemon).also { gateway = it }).also {
            it.ensureOnline()
        }

    @Synchronized
    override fun close() {
        gateway?.close()
        gateway = null
    }
}
