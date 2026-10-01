package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.RemoteDesktopDisplayMode
import com.dbpprt.dieter.api.v1.RemoteDesktopDisplayModes
import com.dbpprt.dieter.api.v1.RemoteDesktopRef
import com.dbpprt.dieter.api.v1.SetRemoteDesktopDisplayModeRequest
import com.dbpprt.dieter.core.screens.DisplayMatching
import com.dbpprt.dieter.core.screens.ScreenDisplays
import com.squareup.wire.GrpcCall
import java.io.IOException
import java.lang.reflect.Proxy
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Resolution matching against a scripted host: changes run one at a time, a
 * temporary mode is restored when matching stops (even mid-change), and a
 * failed or repeated request does not keep changing the host's desktop.
 */
class ScreenDisplaysTest {
    private val core = Dispatchers.Default.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + core)
    private val target = DisplayMatching.Target(1280.0, 720.0, 1.0, 60.0)

    @AfterTest
    fun tearDown() = scope.cancel()

    private class Host(val failAfterSet: Boolean = false) {
        @Volatile var current = "original"
        @Volatile var setStarted = false
        val operations = CopyOnWriteArrayList<String>()

        val client: DieterServiceClient = Proxy.newProxyInstance(DieterServiceClient::class.java.classLoader, arrayOf(DieterServiceClient::class.java)) { _, method, _ ->
            when (method.name) {
                "ListRemoteDesktopDisplayModes" -> GrpcCall<RemoteDesktopRef, RemoteDesktopDisplayModes> {
                    operations += "list"
                    RemoteDesktopDisplayModes(
                        display_id = "screen", current_mode_id = current,
                        modes = listOf(RemoteDesktopDisplayMode(id = "matched", logical_width = 1280, logical_height = 720, pixel_width = 1280, pixel_height = 720, refresh_rate = 60.0)),
                    )
                }
                "SetRemoteDesktopDisplayMode" -> GrpcCall<SetRemoteDesktopDisplayModeRequest, RemoteDesktopDisplayModes> { request ->
                    operations += "set"
                    current = request.mode_id
                    setStarted = true
                    // A slow host: the reply arrives while the viewer changes its mind.
                    Thread.sleep(200)
                    if (failAfterSet) throw IOException("the host dropped the change")
                    RemoteDesktopDisplayModes(temporary = true)
                }
                "RestoreRemoteDesktopDisplayMode" -> GrpcCall<RemoteDesktopRef, RemoteDesktopDisplayModes> {
                    operations += "restore"
                    current = "original"
                    RemoteDesktopDisplayModes()
                }
                else -> error("unexpected RPC ${method.name}")
            }
        } as DieterServiceClient
    }

    private suspend fun <T> onCore(block: () -> T): T = withContext(core) { block() }

    /** Polls a condition on the core dispatcher; the host's progress is not published through the view. */
    private suspend fun eventually(describe: () -> String, condition: () -> Boolean) {
        withTimeoutOrNull(10.seconds) { while (!onCore(condition)) delay(10) } ?: error("timed out waiting for ${describe()}")
    }

    @Test
    fun stoppingWhileAChangeIsInFlightRestoresAfterTheReply() = runBlocking {
        val host = Host()
        val displays = ScreenDisplays(scope) {}
        onCore { displays.update(ScreenDisplays.Intent(host.client, "viewer", "screen", target)) }
        eventually({ "set started" }) { host.setStarted }
        onCore { displays.update(null) }
        eventually({ "settled: ${host.operations}" }) { !displays.view.value.busy && host.operations.size == 3 }
        assertEquals(listOf("list", "set", "restore"), host.operations.toList())
        assertEquals("original", host.current)
    }

    @Test
    fun failedOrRepeatedRequestsDoNotKeepChangingTheDesktop() = runBlocking {
        val host = Host(failAfterSet = true)
        val displays = ScreenDisplays(scope) {}
        val intent = ScreenDisplays.Intent(host.client, "viewer", "screen", target)
        onCore { displays.update(intent) }
        eventually({ "failure: ${displays.view.value}" }) { displays.view.value.let { it.status.contains("unavailable") && !it.busy } }
        val failed = displays.view.value
        assertTrue(failed.status.startsWith("Resolution matching unavailable"), failed.status)
        onCore { repeat(10) { displays.update(intent) } }
        delay(450)
        assertEquals(listOf("list", "set", "restore"), host.operations.toList())
        assertEquals("original", host.current)
    }
}
