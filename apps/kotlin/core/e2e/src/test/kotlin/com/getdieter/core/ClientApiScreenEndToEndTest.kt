package com.getdieter.core

import com.getdieter.client.v1.Command
import com.getdieter.client.v1.ScreenCommand
import com.getdieter.client.v1.ScreenConnect
import com.getdieter.client.v1.ScreenDisplayTarget
import com.getdieter.client.v1.ScreenSlice
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Step
import com.getdieter.client.v1.Update
import com.getdieter.core.client.ClientApi
import com.getdieter.core.client.ScreenHost
import com.getdieter.core.screens.RtpCodec
import com.getdieter.core.screens.ScreenConfig
import com.getdieter.core.screens.ScreenMediaCapabilities
import com.getdieter.core.screens.ScreenMediaConfig
import com.getdieter.core.screens.ScreenMediaEngine
import com.getdieter.core.screens.ScreenMediaEngineFactory
import com.getdieter.core.screens.ScreenMediaEvents
import com.getdieter.core.screens.ViewportPolicy
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The screen contract over the real gateway and daemon: a screen surface resolves its route and the
 * host's capabilities, and the isolated host, which has no capture helper, settles on its reason. A
 * core without a media engine reports that screen sharing is unavailable.
 */
class ClientApiScreenEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    private object NoMedia : ScreenMediaEngineFactory {
        override val capabilities =
            ScreenMediaCapabilities(listOf(RtpCodec("H264", "640c1f")), false, false, false)

        override fun create(
            config: ScreenMediaConfig,
            events: ScreenMediaEvents,
        ): ScreenMediaEngine = error("the isolated host cannot stream")
    }

    @Test
    fun aScreenSurfaceResolvesItsRouteAndSettles() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val scopes = mutableListOf<String>()
        val api =
            ClientApi(
                runtime,
                ScreenHost(
                    { scope ->
                        scopes += scope
                        NoMedia
                    },
                    null,
                    ScreenConfig("Core test", ViewportPolicy.Desktop),
                ),
            )
        val screen = MutableStateFlow<ScreenSlice?>(null)
        val watch =
            api.observe(Slice.SLICE_SCREEN, "screen-test") {
                screen.value = Update.ADAPTER.decode(it.encode()).screen
            }
        fun command(action: ScreenCommand) = Command(screen = action.copy(scope = "screen-test"))
        api.dispatch(command(ScreenCommand(connect = ScreenConnect(daemon_id = fixture.daemonId))))
        val settled =
            screen.await(describe = { "settled: ${screen.value}" }) {
                it?.phase in setOf("unsupported", "permission_required", "failed")
            }!!
        assertTrue(settled.phase != "failed", "the route and capabilities load: ${settled.problem}")
        assertEquals(false, assertNotNull(settled.capabilities).ready)
        assertTrue(settled.route_label.isNotEmpty())
        assertTrue(settled.problem.isNotEmpty())
        // A blocked session words its phase and offers no control, clipboard, or latency.
        assertEquals(
            if (settled.phase == "unsupported") "Screen sharing unavailable"
            else "Permission required",
            settled.phase_label,
        )
        assertEquals("— ms RTT", settled.latency_label)
        assertEquals("", settled.control_unavailable_reason)
        assertFalse(settled.clipboard_actions_enabled)
        assertTrue(settled.frame_rates.isNotEmpty())
        assertEquals(listOf("screen-test"), scopes, "the view's engines are made for its scope")
        // Matching needs control of a running session; without one it waits quietly.
        api.dispatch(
            command(
                ScreenCommand(
                    match_display = ScreenDisplayTarget(width = 1512.0, height = 982.0, scale = 2.0)
                )
            )
        )
        api.dispatch(command(ScreenCommand(disconnect = Step())))
        assertEquals(
            "Not connected",
            screen
                .await(describe = { "idle: ${screen.value?.phase}" }) { it?.phase == "idle" }!!
                .phase_label,
        )
        watch.close()

        // Without a media engine the slice reports that screens are unavailable.
        val failures = MutableStateFlow<String?>(null)
        val bare =
            ClientApi(runtime).observe(Slice.SLICE_SCREEN, "bare") {
                failures.value = Update.ADAPTER.decode(it.encode()).failure?.message
            }
        failures.await(describe = { "failure" }) { it?.contains("unavailable") == true }
        bare.close()
    }
}
