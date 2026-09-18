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
            controller = androidx.compose.runtime.remember { ScreenController(context).apply {
                lowLatencyDecoding = InstrumentationRegistry.getArguments().getString("screenLowLatency") != "0"
                surfacePresentation = InstrumentationRegistry.getArguments().getString("screenSurface") == "1"
                directSurfacePresentation = InstrumentationRegistry.getArguments().getString("screenDirectSurface") == "1"
            } }
            DieterTheme { androidx.compose.material3.Scaffold { padding ->
                ScreenWorkspace(listOf(EndpointConnection("fixture", "Codec test Mac", "isolated", daemonId = "d_screens_fixture")), padding, controller) { open() }
            } }
        }
        fun waitVideo(codec: String) {
            compose.waitUntil(30_000) { controller.state.value.phase == "failed" ||
                (controller.state.value.phase == "streaming" && controller.state.value.session.codec == codec && controller.state.value.receivedFps > 0) }
            assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
            assertEquals(codec, controller.state.value.session.codec)
            val endpoint = if (controller.directSurfacePresentation)
                com.dbpprt.dieter.v1.RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED
                else com.dbpprt.dieter.v1.RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED
            compose.waitUntil(5_000) { controller.state.value.session.renderMeasurement == endpoint && controller.state.value.decodedFrames > 0 }
        }
        val timestamps = java.util.Collections.synchronizedSet(linkedSetOf<Long>())
        val arrivals = ArrayDeque<Long>()
        val results = org.json.JSONArray()
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
            var previousObserver: ((Long) -> Unit)? = null
            var observer: ((Long) -> Unit)? = null
            compose.runOnIdle {
                previousObserver = controller.decodedOutputObserver
                synchronized(timestamps) { timestamps.clear(); arrivals.clear() }
                observer = { timestamp ->
                    synchronized(timestamps) {
                        if (timestamps.size >= 1024) timestamps.remove(timestamps.first())
                        if (timestamps.add((timestamp / 1_000_000L * 90L) and 0xffff_ffffL)) {
                            if (arrivals.size >= 16) arrivals.removeFirst()
                            arrivals.addLast(android.os.SystemClock.elapsedRealtime())
                        }
                    }
                    previousObserver?.invoke(timestamp)
                }
                controller.decodedOutputObserver = observer
            }
            try {
                compose.waitUntil(15_000) { controller.state.value.session.referenceAcks > 0 }
                val before = controller.state.value.session.referenceRecoveries
                fault("burst")
                try { compose.waitUntil(15_000) { controller.state.value.session.referenceRecoveries > before } }
                catch (failure: Throwable) {
                    android.util.Log.e("DieterRecovery", "$codec missing decoded LTR ACK; fault=${fault()}; ${controller.state.value.session}")
                    throw failure
                }
                android.util.Log.i("DieterRecovery", "$codec LTR recovery decoded and acknowledged")
                fault("random")
                compose.waitUntil(15_000) { controller.state.value.session.fecPercent > 0 && controller.state.value.session.fecPackets > 0 }
                fault("none")
                // Random loss can leave an earlier reference dependency unresolved.
                // A fixed sleep cannot prove that the next protected frame is
                // otherwise decodable. Require actual continuous decoder output
                // before isolating a single FEC repair; retain the exact-RTP proof.
                synchronized(timestamps) { arrivals.clear() }
                val cleanStarted = android.os.SystemClock.elapsedRealtime()
                compose.waitUntil(10_000) {
                    synchronized(timestamps) {
                        arrivals.size == 16 && arrivals.zipWithNext().all { (a, b) -> b - a <= 250 } &&
                            android.os.SystemClock.elapsedRealtime() - arrivals.last() <= 250
                    }
                }
                assertTrue("Adaptive FEC must remain enabled for the isolated repair", controller.state.value.session.fecPercent > 0)
                val cleanElapsed = android.os.SystemClock.elapsedRealtime() - cleanStarted
                android.util.Log.i("DieterRecovery", "$codec continuous decode resumed after random loss in $cleanElapsed ms")
                val proofStarted = android.os.SystemClock.elapsedRealtime()
                fault("fec-proof")
                var repaired = 0L
                val deadline = android.os.SystemClock.elapsedRealtime() + 2_000
                while (repaired == 0L && android.os.SystemClock.elapsedRealtime() < deadline) {
                    repaired = fault().getLong("repairedTimestamp")
                    if (repaired == 0L) Thread.sleep(25)
                }
                assertTrue("Fixture must discard a protected packet: ${fault()}; fec=${controller.state.value.session.fecPercent}", repaired != 0L)
                val quantized = repaired / 90L * 90L
                try { compose.waitUntil(10_000) { timestamps.contains(quantized) } }
                catch (failure: Throwable) {
                    val observed = synchronized(timestamps) { timestamps.toList() }
                    android.util.Log.e("DieterRecovery", "Missing $repaired / $quantized; count=${observed.size} range=${observed.minOrNull()}..${observed.maxOrNull()} nativeDecoded=${controller.state.value.decodedFrames} observerCurrent=${controller.decodedOutputObserver === observer}; nearest=${observed.sortedBy { kotlin.math.abs(it - quantized) }.take(8)}; ${controller.state.value.session}")
                    throw failure
                }
                android.util.Log.i("DieterRecovery", "$codec FEC reconstructed RTP $repaired with original and retransmissions discarded")
                results.put(JSONObject().apply {
                    put("codec", codec)
                    put("decoder", controller.decoderStatus?.implementation)
                    put("presentationEndpoint", controller.state.value.session.renderMeasurement.name)
                    put("nativeFramesDecoded", controller.state.value.decodedFrames)
                    put("referenceRecoveries", controller.state.value.session.referenceRecoveries - before)
                    put("protectedRtpTimestamp", repaired)
                    put("decodedQuantizedRtpTimestamp", quantized)
                    // Includes the 16-frame continuity check / HTTP polling;
                    // neither value is an input-to-photon measurement.
                    put("postLossContinuityCheckMs", cleanElapsed)
                    put("fecProbeToObservedDecodeMs", android.os.SystemClock.elapsedRealtime() - proofStarted)
                    put("fault", fault())
                })
                fault("none")
                val capture = captureScreenFixture()
                File(context.getExternalFilesDir(null), "screen-recovery-$codec.png").outputStream().use { capture.compress(Bitmap.CompressFormat.PNG, 100, it) }
            } finally {
                compose.runOnIdle { if (controller.decodedOutputObserver === observer) controller.decodedOutputObserver = previousObserver }
            }
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
            File(context.getExternalFilesDir(null), "screen-recovery.json").writeText(
                JSONObject().put("schemaVersion", 1).put("cases", results).toString())
        } finally {
            fault("none")
            compose.runOnIdle { controller.close() }
        }
    }
}
