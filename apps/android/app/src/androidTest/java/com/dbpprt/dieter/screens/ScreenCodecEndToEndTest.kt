package com.dbpprt.dieter.screens

import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.ui.ScreenWorkspace
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.DieterServiceGrpcKt
import io.grpc.Metadata
import io.grpc.okhttp.OkHttpChannelBuilder
import io.grpc.stub.MetadataUtils
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.Base64

/** Codec UI and compatibility against the disposable authenticated screen fixture. */
class ScreenCodecEndToEndTest {
    @get:Rule val compose = createComposeRule()

    @Test fun codecSelectionAndHardwareAdmission() {
        val encoded = InstrumentationRegistry.getArguments().getString("screenFixture")
        assumeTrue("Requires the isolated screen fixture", encoded != null)
        val fixture = JSONObject(String(Base64.getDecoder().decode(encoded)))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        lateinit var controller: ScreenController
        suspend fun open(): ScreenConnection {
            val channel = OkHttpChannelBuilder.forAddress("127.0.0.1", fixture.getInt("port")).usePlaintext().build()
            val headers = Metadata().apply { put(Metadata.Key.of("authorization", Metadata.ASCII_STRING_MARSHALLER), "Bearer ${fixture.getString("token")}") }
            return ScreenConnection(DieterServiceGrpcKt.DieterServiceCoroutineStub(channel).withInterceptors(MetadataUtils.newAttachHeadersInterceptor(headers)),
                Base64.getDecoder().decode(fixture.getString("certificate")), RTCConfiguration.parseFrom(Base64.getDecoder().decode(fixture.getString("rtc"))),
                "Isolated codec fixture") { channel.shutdownNow() }
        }
        compose.setContent {
            controller = androidx.compose.runtime.remember { ScreenController(context).apply {
                lowLatencyDecoding = InstrumentationRegistry.getArguments().getString("screenLowLatency") != "0"
                surfacePresentation = InstrumentationRegistry.getArguments().getString("screenSurface") == "1"
                directSurfacePresentation = InstrumentationRegistry.getArguments().getString("screenDirectSurface") == "1"
            } }
            DieterTheme { androidx.compose.material3.Scaffold { padding ->
                ScreenWorkspace(listOf(EndpointConnection("fixture", "Codec test Mac", "isolated", daemonId = "d_screens_fixture")), padding, controller) { open() }
            } }
        }
        fun waitVideo(codec: String, directOutput: Boolean = controller.directSurfacePresentation) {
            compose.waitUntil(30_000) { controller.state.value.phase == "failed" ||
                (controller.state.value.phase == "streaming" && controller.state.value.session.codec == codec && controller.state.value.receivedFps > 0) }
            assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
            assertEquals(codec, controller.state.value.session.codec)
            assertNotNull("Actual decoder configuration must be observable", controller.decoderStatus)
            val status = requireNotNull(controller.decoderStatus)
            android.util.Log.i("DieterScreenCodec", "$codec decoder=$status")
            val endpoint = if (directOutput)
                com.dbpprt.dieter.v1.RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED
                else com.dbpprt.dieter.v1.RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED
            compose.waitUntil(5_000) { controller.state.value.session.renderMeasurement == endpoint }
            assertEquals(endpoint, controller.state.value.session.renderMeasurement)
            assertTrue("JNI decode-completion statistics must advance", controller.state.value.decodedFrames > 0)
            File(context.getExternalFilesDir(null), "screen-decoder-$codec.json").writeText(JSONObject(mapOf(
                "schemaVersion" to 1, "sessionId" to controller.id,
                "codec" to codec, "implementation" to status.implementation, "hardware" to status.hardware,
                "lowLatencyRequested" to status.lowLatencyRequested, "lowLatencyAccepted" to status.lowLatencyAccepted,
                "reason" to status.reason, "renderEndpoint" to endpoint.name,
                "nativeFramesDecoded" to controller.state.value.decodedFrames,
                "directRequested" to controller.directSurfacePresentation,
                "renderSurface" to if (directOutput) "mediacodec-direct" else if (controller.surfacePresentation) "surface-view-egl" else "texture-view-egl",
            )).toString())
        }
        fun choose(label: String) {
            compose.onNodeWithContentDescription("Screen quality").performClick()
            compose.onNodeWithText(label).performClick()
        }
        try {
            compose.onNodeWithTag("screen-machine").performClick()
            compose.onNodeWithText("Codec test Mac").performClick()
            compose.onNodeWithTag("screen-connect").performClick()
            waitVideo("H264")
            if (controller.directSurfacePresentation) {
                val oldSurface = requireNotNull(controller.decoderSurface)
                // Decode real output but withhold direct presentation. The
                // bounded watchdog must retire this target once, reconnect,
                // and deliver normal texture frames through the genuine sink.
                val sink = controller.videoSink
                compose.runOnIdle {
                    controller.videoSink = { frame, session ->
                        if (frame.buffer !is org.webrtc.VideoFrame.SurfaceBuffer) sink?.invoke(frame, session)
                    }
                    controller.resumeConnection()
                }
                waitVideo("H264", directOutput = false)
                assertFalse(oldSurface.isOpen)
                compose.runOnIdle { controller.videoSink = sink }
                lateinit var view: android.view.View
                compose.runOnIdle {
                    view = requireNotNull(android.view.inspector.WindowInspector.getGlobalWindowViews()
                        .firstNotNullOfOrNull { it.findViewWithTag<android.view.View>("dieter-direct-output") })
                    view.visibility = android.view.View.INVISIBLE
                }
                compose.waitUntil(5_000) { controller.decoderSurface == null }
                compose.runOnIdle { view.visibility = android.view.View.VISIBLE }
                compose.waitUntil(5_000) { controller.decoderSurface != null && controller.decoderSurface !== oldSurface }
                waitVideo("H264")
            }
            val first = controller.id
            var hevc = false
            compose.runOnIdle { hevc = ScreenDecoderFactory(controller.egl.eglBaseContext, enableHEVC = true) {}.supportedCodecs.any { it.name == "H265" } }
            android.util.Log.i("DieterHEVC", "Hardware HEVC admission: $hevc")
            choose("Automatic codec")
            compose.waitUntil(10_000) { controller.id.isNotEmpty() && controller.id != first }
            waitVideo(if (hevc) "H265" else "H264")
            if (hevc) {
                // Inject the native decoder's initialization-failure notification,
                // then verify a real authenticated H.264 reconnection and retention.
                compose.runOnIdle { controller.hevcUnavailable() }
                waitVideo("H264")
                assertTrue(controller.state.value.codecFallbackReason.contains("HEVC unavailable"))
                val fallbackSession = controller.id
                compose.runOnIdle { controller.resumeConnection() }
                compose.waitUntil(10_000) { controller.id.isNotEmpty() && controller.id != fallbackSession }
                waitVideo("H264")
            }
            choose("HEVC · up to 1080p60")
            if (hevc) {
                waitVideo("H265")
                val hevcCapture = captureScreenFixture()
                File(context.getExternalFilesDir(null), "screen-hevc.png").outputStream().use { hevcCapture?.compress(Bitmap.CompressFormat.PNG, 100, it) }
                // Strict HEVC cannot silently accept the H.264-only 120fps mode.
                choose("Up to 120 fps")
            }
            run {
                compose.waitUntil(10_000) { controller.state.value.phase == "failed" }
                assertTrue(controller.state.value.error.contains("HEVC"))
                assertTrue(controller.id.isEmpty())
                // Failure preserves the selected preference; a new explicit
                // connection with H.264 must recover without replacing credentials.
                choose("H.264 compatibility")
                compose.onNodeWithTag("screen-connect").performClick()
            }
            waitVideo("H264")
            val capture = captureScreenFixture()
            File(context.getExternalFilesDir(null), "screen-codec.png").outputStream().use { capture?.compress(Bitmap.CompressFormat.PNG, 100, it) }
        } finally { compose.runOnIdle { controller.close() } }
    }
}
