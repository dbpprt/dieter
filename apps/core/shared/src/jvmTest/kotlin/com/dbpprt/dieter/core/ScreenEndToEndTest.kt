package com.dbpprt.dieter.core

import com.dbpprt.dieter.core.screens.RtpCodec
import com.dbpprt.dieter.core.screens.ScreenConfig
import com.dbpprt.dieter.core.screens.ScreenMediaCapabilities
import com.dbpprt.dieter.core.screens.ScreenMediaConfig
import com.dbpprt.dieter.core.screens.ScreenMediaEngine
import com.dbpprt.dieter.core.screens.ScreenMediaEngineFactory
import com.dbpprt.dieter.core.screens.ScreenMediaEvents
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.screens.ViewportPolicy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * SCREENS scenario over the real gateway and daemon: the route factory
 * resolves the enrolled certificate and ICE servers, and the session reads
 * the host's capabilities through the machine's data plane. The isolated
 * daemon has no capture helper, so the session settles on its reason.
 */
class ScreenEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    private object NoMedia : ScreenMediaEngineFactory {
        override val capabilities = ScreenMediaCapabilities(listOf(RtpCodec("H264", "640c1f")), false, false, false)
        override fun create(config: ScreenMediaConfig, events: ScreenMediaEvents): ScreenMediaEngine = error("the isolated host cannot stream")
    }

    @Test
    fun routesResolveAndCapabilitiesSettle() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val screen = runtime.onCore { runtime.screen(NoMedia, ScreenConfig("Core test", ViewportPolicy.Fixed)) }
        runtime.onCore { screen.connect(runtime.screenRoutes(fixture.daemonId)) }
        val settled = screen.view.await(describe = { "settled: ${screen.view.value}" }) {
            it.phase is ScreenPhase.Unsupported || it.phase is ScreenPhase.PermissionRequired || it.phase is ScreenPhase.Failed
        }
        assertTrue(settled.phase !is ScreenPhase.Failed, "the route and capabilities load: ${settled.phase}")
        val capabilities = assertNotNull(settled.capabilities)
        assertEquals(false, capabilities.ready)
        assertTrue(settled.routeLabel.isNotEmpty())
        runtime.onCore { screen.disconnect() }
        assertEquals(ScreenPhase.Idle, screen.view.value.phase)
    }
}
