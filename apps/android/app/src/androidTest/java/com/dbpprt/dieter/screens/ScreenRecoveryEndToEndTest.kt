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

/** Actual hardware decoder completions under loss on the isolated authenticated fixture. */
class ScreenRecoveryEndToEndTest {
    @get:Rule val compose = createComposeRule()

    @Test fun acknowledgedReferencesAndFlexFEC() {
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
            controller = androidx.compose.runtime.remember { ScreenController(context) }
            DieterTheme { androidx.compose.material3.Scaffold { padding ->
                ScreenWorkspace(listOf(EndpointConnection("fixture", "Codec test Mac", "isolated", daemonId = "d_screens_fixture")), padding, controller) { open() }
            } }
        }
        fun waitVideo(codec: String) {
            compose.waitUntil(30_000) { controller.state.value.phase == "failed" ||
                (controller.state.value.phase == "streaming" && controller.state.value.session.codec == codec && controller.state.value.receivedFps > 0) }
            assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
            assertEquals(codec, controller.state.value.session.codec)
        }
        val timestamps = java.util.Collections.synchronizedSet(mutableSetOf<Long>())
        fun fault(mode: String? = null): JSONObject {
            val url = java.net.URL("http://127.0.0.1:${fixture.getInt("port")}/test/media-loss" + (mode?.let { "?mode=$it" } ?: ""))
            val connection = url.openConnection() as java.net.HttpURLConnection
            connection.connectTimeout = 3000; connection.readTimeout = 3000
            connection.setRequestProperty("Authorization", "Bearer ${fixture.getString("token")}")
            if (mode != null) connection.requestMethod = "POST"
            try {
                assertEquals(200, connection.responseCode)
                return JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            } finally { connection.disconnect() }
        }
        fun exercise(codec: String) {
            waitVideo(codec)
            compose.runOnIdle {
                val sink = controller.videoSink
                controller.videoSink = { frame, token ->
                    synchronized(timestamps) {
                        if (timestamps.size > 512) timestamps.clear()
                        timestamps.add((frame.timestampNs / 1_000_000L * 90L) and 0xffff_ffffL)
                    }
                    sink?.invoke(frame, token)
                }
            }
            compose.waitUntil(15_000) { controller.state.value.session.referenceAcks > 0 }
            val before = controller.state.value.session.referenceRecoveries
            fault("burst")
            compose.waitUntil(15_000) { controller.state.value.session.referenceRecoveries > before }
            android.util.Log.i("DieterRecovery", "$codec LTR recovery decoded and acknowledged")
            fault("random")
            compose.waitUntil(15_000) { controller.state.value.session.fecPercent > 0 && controller.state.value.session.fecPackets > 0 }
            fault("none")
            Thread.sleep(500)
            fault("fec-proof")
            var repaired = 0L
            val deadline = android.os.SystemClock.elapsedRealtime() + 2_000
            while (repaired == 0L && android.os.SystemClock.elapsedRealtime() < deadline) {
                repaired = fault().getLong("repairedTimestamp")
                if (repaired == 0L) Thread.sleep(25)
            }
            assertTrue("Fixture must discard a protected packet", repaired != 0L)
            val quantized = repaired / 90L * 90L
            try { compose.waitUntil(10_000) { timestamps.contains(quantized) } }
            catch (failure: Throwable) {
                android.util.Log.e("DieterRecovery", "Missing $repaired / $quantized; nearest=${synchronized(timestamps) { timestamps.sortedBy { kotlin.math.abs(it - quantized) }.take(8) }}; ${controller.state.value.session}")
                throw failure
            }
            android.util.Log.i("DieterRecovery", "$codec FEC reconstructed RTP $repaired with original and retransmissions discarded")
            fault("none")
            val capture = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            File(context.getExternalFilesDir(null), "screen-recovery-$codec.png").outputStream().use { capture?.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        try {
            compose.onNodeWithTag("screen-machine").performClick()
            compose.onNodeWithText("Codec test Mac").performClick()
            compose.onNodeWithTag("screen-connect").performClick()
            exercise("H264")
            var hevc = false
            compose.runOnIdle { hevc = ScreenDecoderFactory(controller.egl.eglBaseContext, enableHEVC = true) {}.supportedCodecs.any { it.name == "H265" } }
            assertTrue("The selected hardware-accelerated test AVD must support HEVC", hevc)
            compose.onNodeWithContentDescription("Screen quality").performClick()
            compose.onNodeWithText("HEVC · up to 1080p60").performClick()
            exercise("H265")
        } finally {
            fault("none")
            compose.runOnIdle { controller.close() }
        }
    }
}
