package com.dbpprt.dieter.core.testing

import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.RuntimeConfig
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.connection.SyncState
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.platform.Platform
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking

/**
 * Owns the fixtures and runtimes of one end-to-end test and tears them down.
 * Every runtime uses a private state directory and the fixture's disposable
 * credentials.
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
        configure: (RuntimeConfig) -> RuntimeConfig = { it },
    ): CoreRuntime {
        val config = configure(RuntimeConfig(clientVersion, "dieter-test://oauth/callback", includeLoopbackRoutes = true, clientIdPrefix = "e2e"))
        val runtime = CoreRuntime(platform, config)
        runtimes += runtime
        val gateway = requireNotNull(Gateway.parse(fixture.url))
        runtime.setGateways(listOf(gateway), gateway.origin)
        if (token != null) runtime.credentials.save(gateway, token)
        runtime.start()
        runtime.setActive(active)
        return runtime
    }

    suspend fun CoreRuntime.awaitConnected(timeout: Duration = 30.seconds) =
        connection.state.await(timeout, describe = { "connected: ${connection.state.value}" }) { it.phase == ConnectionPhase.CONNECTED }

    suspend fun CoreRuntime.awaitLoaded(fixture: IsolatedGateway) =
        workspace.state.await(describe = { "project ${fixture.projectId}" }) { it.project(fixture.projectId) != null }

    /** Waits until [machineId]'s part of the account view is in [state]. */
    suspend fun CoreRuntime.awaitSync(machineId: String, state: SyncState, timeout: Duration = 30.seconds) =
        connection.syncs.await(timeout, describe = { "$machineId $state: ${connection.syncs.value[machineId]}" }) { it[machineId]?.state == state }

    companion object {
        const val RELEASE = "0.0.0-dev.0"
    }
}
