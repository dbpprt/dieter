package com.dbpprt.dieter.screens

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.api.v1.RemoteDesktopRenderMeasurement
import com.dbpprt.dieter.e2e.Evidence
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.ui.ScreenWorkspace
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Codec UI and compatibility against the disposable authenticated screen fixture. */
class ScreenCodecEndToEndTest {
    @get:Rule val compose = createComposeRule()

    @Test fun codecSelectionAndHardwareAdmission() {
        val fixture = ScreenFixture.fromArguments()
        assumeTrue("Requires the isolated screen fixture", fixture != null)
        fixture!!
        val arguments = InstrumentationRegistry.getArguments()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val host = fixture.host(context) {
            lowLatencyDecoding = arguments.getString("screenLowLatency") != "0"
            surfacePresentation = arguments.getString("screenSurface") == "1"
            directSurfacePresentation = arguments.getString("screenDirectSurface") == "1"
        }
        val media = host.media
        fun view() = host.view.value
        fun failure() = (view().phase as? ScreenPhase.Failed)?.message
        compose.setContent {
            DieterTheme { androidx.compose.material3.Scaffold { padding ->
                ScreenWorkspace(listOf(MachineRow("d_screens_fixture", "Codec test Mac", "isolated", daemonId = "d_screens_fixture")), padding, host) {}
            } }
        }
        fun waitVideo(codec: String, directOutput: Boolean = media.directSurfacePresentation) {
            compose.waitUntil(30_000) { view().phase is ScreenPhase.Failed ||
                (view().phase == ScreenPhase.Streaming && view().state?.codec == codec && host.stats.value.fps > 0) }
            assertEquals(failure(), ScreenPhase.Streaming, view().phase)
            assertEquals(codec, view().state?.codec)
            assertNotNull("Actual decoder configuration must be observable", media.decoderStatus)
            val status = requireNotNull(media.decoderStatus)
            android.util.Log.i("DieterScreenCodec", "$codec decoder=$status")
            val endpoint = if (directOutput) RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED
                else RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED
            compose.waitUntil(5_000) { view().state?.render_measurement == endpoint }
            assertEquals(endpoint, view().state?.render_measurement)
            assertTrue("JNI decode-completion statistics must advance", host.stats.value.decodedFrames > 0)
            Evidence.text("screen-decoder-$codec.json", JSONObject(mapOf(
                "schemaVersion" to 1, "sessionId" to view().sessionId,
                "codec" to codec, "implementation" to status.implementation, "hardware" to status.hardware,
                "lowLatencyRequested" to status.lowLatencyRequested, "lowLatencyAccepted" to status.lowLatencyAccepted,
                "reason" to status.reason, "renderEndpoint" to endpoint.name,
                "nativeFramesDecoded" to host.stats.value.decodedFrames,
                "directRequested" to media.directSurfacePresentation,
                "renderSurface" to if (directOutput) "mediacodec-direct" else if (media.surfacePresentation) "surface-view-egl" else "texture-view-egl",
            )).toString())
        }
        fun choose(label: String) {
            compose.onNodeWithContentDescription("Screen quality").performClick()
            compose.onNodeWithText(label).performClick()
        }
        fun awaitNewSession(previous: String) = compose.waitUntil(10_000) { view().sessionId.isNotEmpty() && view().sessionId != previous }
        try {
            compose.onNodeWithText("Codec test Mac").performClick()
            waitVideo("H264")
            if (media.directSurfacePresentation) {
                val oldSurface = requireNotNull(media.decoderSurface)
                // Decode real output but withhold direct presentation. The
                // bounded watchdog must retire this target once, reconnect,
                // and deliver normal texture frames through the genuine sink.
                val sink = media.videoSink
                compose.runOnIdle {
                    media.videoSink = { frame, session ->
                        if (frame.buffer !is org.webrtc.VideoFrame.SurfaceBuffer) sink?.invoke(frame, session)
                    }
                    host.resume()
                }
                waitVideo("H264", directOutput = false)
                assertFalse(oldSurface.isOpen)
                compose.runOnIdle { media.videoSink = sink }
                lateinit var view: android.view.View
                compose.runOnIdle {
                    view = requireNotNull(android.view.inspector.WindowInspector.getGlobalWindowViews()
                        .firstNotNullOfOrNull { it.findViewWithTag<android.view.View>("dieter-direct-output") })
                    view.visibility = android.view.View.INVISIBLE
                }
                compose.waitUntil(5_000) { media.decoderSurface == null }
                compose.runOnIdle { view.visibility = android.view.View.VISIBLE }
                compose.waitUntil(5_000) { media.decoderSurface != null && media.decoderSurface !== oldSurface }
                waitVideo("H264")
            }
            val first = view().sessionId
            val hevc = media.capabilities.hevcDecoder
            android.util.Log.i("DieterHEVC", "Hardware HEVC admission: $hevc")
            choose("Automatic codec")
            awaitNewSession(first)
            waitVideo(if (hevc) "H265" else "H264")
            if (hevc) {
                // Inject the native decoder's initialization-failure notification,
                // then verify a real authenticated H.264 reconnection and retention.
                compose.runOnIdle { media.reportHevcUnavailable() }
                waitVideo("H264")
                assertTrue(view().codecFallbackReason.orEmpty().contains("HEVC unavailable"))
                val fallbackSession = view().sessionId
                compose.runOnIdle { host.resume() }
                awaitNewSession(fallbackSession)
                waitVideo("H264")
            }
            choose("HEVC · up to 1080p60")
            if (hevc) {
                waitVideo("H265")
                val hevcCapture = captureScreenFixture()
                Evidence.save(hevcCapture, "screen-hevc.png")
                // Strict HEVC cannot silently accept the H.264-only 120fps mode.
                choose("Up to 120 fps")
            }
            run {
                compose.waitUntil(10_000) { view().phase is ScreenPhase.Failed }
                assertTrue(failure().orEmpty().contains("HEVC"))
                assertTrue(view().sessionId.isEmpty())
                // Failure preserves the selected preference; a new explicit
                // connection with H.264 must recover without replacing credentials.
                choose("H.264 compatibility")
                compose.onNodeWithTag("screen-connect").performClick()
            }
            waitVideo("H264")
            val capture = captureScreenFixture()
            Evidence.save(capture, "screen-codec.png")
        } finally {
            compose.runOnIdle { host.close() }
            fixture.close()
        }
    }
}
