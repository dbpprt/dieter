package com.dbpprt.dieter.screens

import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.api.v1.RemoteDesktopRenderMeasurement
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.ui.ScreenWorkspace
import com.dbpprt.dieter.ui.theme.DieterTheme
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Actual hardware decoder completions under loss on the isolated authenticated fixture. */
class ScreenRecoveryEndToEndTest {
    @get:Rule val compose = createComposeRule()

    @Test fun acknowledgedReferencesAndFlexFEC() {
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
        fun session() = view().state ?: RemoteDesktopSessionState()
        compose.setContent {
            DieterTheme { androidx.compose.material3.Scaffold { padding ->
                ScreenWorkspace(listOf(MachineRow("d_screens_fixture", "Codec test Mac", "isolated", daemonId = "d_screens_fixture")), padding, host) {}
            } }
        }
        fun waitVideo(codec: String) {
            compose.waitUntil(30_000) { view().phase is ScreenPhase.Failed ||
                (view().phase == ScreenPhase.Streaming && session().codec == codec && host.stats.value.fps > 0) }
            assertEquals((view().phase as? ScreenPhase.Failed)?.message, ScreenPhase.Streaming, view().phase)
            assertEquals(codec, session().codec)
            val endpoint = if (media.directSurfacePresentation) RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED
                else RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED
            compose.waitUntil(5_000) { session().render_measurement == endpoint && host.stats.value.decodedFrames > 0 }
        }
        val timestamps = java.util.Collections.synchronizedSet(linkedSetOf<Long>())
        val arrivals = ArrayDeque<Long>()
        val results = org.json.JSONArray()
        fun fault(mode: String? = null): JSONObject {
            val url = java.net.URL("http://127.0.0.1:${fixture.port}/test/media-loss" + (mode?.let { "?mode=$it" } ?: ""))
            val connection = url.openConnection() as java.net.HttpURLConnection
            connection.connectTimeout = 3000; connection.readTimeout = 3000
            connection.setRequestProperty("Authorization", "Bearer ${fixture.token}")
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
                previousObserver = media.decodedOutputObserver
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
                media.decodedOutputObserver = observer
            }
            try {
                compose.waitUntil(15_000) { session().reference_acks > 0 }
                // First decoder output does not prove that its startup backlog
                // has drained. Isolate loss recovery from initial adaptation,
                // using the same actual-output continuity check as after loss.
                compose.waitUntil(30_000) {
                    synchronized(timestamps) {
                        arrivals.size == 16 && arrivals.zipWithNext().all { (a, b) -> b - a <= 250 } &&
                            android.os.SystemClock.elapsedRealtime() - arrivals.last() <= 250 &&
                            session().jitter_buffer_ms < 100
                    }
                }
                android.util.Log.i("DieterRecovery", "$codec pre-loss decoder ready: ${session()}")
                val before = session().reference_recoveries
                fault("burst")
                try { compose.waitUntil(15_000) { session().reference_recoveries > before } }
                catch (failure: Throwable) {
                    android.util.Log.e("DieterRecovery", "$codec missing decoded LTR ACK; fault=${fault()}; ${session()}")
                    throw failure
                }
                android.util.Log.i("DieterRecovery", "$codec LTR recovery decoded and acknowledged")
                fault("random")
                compose.waitUntil(15_000) { session().fec_percent > 0 && session().fec_packets > 0 }
                fault("none")
                // Retire unresolved random-loss dependencies with a fresh,
                // decoded anchor. The following packet is still dropped below
                // FEC generation, including every retransmission: only parity
                // can deliver its exact timestamp to the decoder.
                val anchorBefore = session().reference_acks
                compose.runOnIdle { host.refresh() }
                compose.waitUntil(5_000) { session().reference_acks > anchorBefore }
                assertTrue("Adaptive FEC must remain enabled for the isolated repair", session().fec_percent > 0)
                val proofStarted = android.os.SystemClock.elapsedRealtime()
                fault("fec-proof")
                var repaired = 0L
                val deadline = android.os.SystemClock.elapsedRealtime() + 2_000
                while (repaired == 0L && android.os.SystemClock.elapsedRealtime() < deadline) {
                    repaired = fault().getLong("repairedTimestamp")
                    if (repaired == 0L) Thread.sleep(25)
                }
                assertTrue("Fixture must discard a protected packet: ${fault()}; fec=${session().fec_percent}", repaired != 0L)
                val quantized = repaired / 90L * 90L
                try { compose.waitUntil(10_000) { timestamps.contains(quantized) } }
                catch (failure: Throwable) {
                    val observed = synchronized(timestamps) { timestamps.toList() }
                    android.util.Log.e("DieterRecovery", "Missing $repaired / $quantized; count=${observed.size} range=${observed.minOrNull()}..${observed.maxOrNull()} nativeDecoded=${host.stats.value.decodedFrames} observerCurrent=${media.decodedOutputObserver === observer}; nearest=${observed.sortedBy { kotlin.math.abs(it - quantized) }.take(8)}; ${session()}")
                    throw failure
                }
                val proofElapsed = android.os.SystemClock.elapsedRealtime() - proofStarted
                android.util.Log.i("DieterRecovery", "$codec FEC reconstructed RTP $repaired with original and retransmissions discarded")
                // Continuity is a postcondition of exact-packet recovery. It
                // must outlive the fault rather than require FEC to stay on
                // after its intentional two-second clean-network expiry.
                synchronized(timestamps) { arrivals.clear() }
                val cleanStarted = android.os.SystemClock.elapsedRealtime()
                compose.waitUntil(10_000) {
                    synchronized(timestamps) {
                        arrivals.size == 16 && arrivals.zipWithNext().all { (a, b) -> b - a <= 250 } &&
                            android.os.SystemClock.elapsedRealtime() - arrivals.last() <= 250
                    }
                }
                val cleanElapsed = android.os.SystemClock.elapsedRealtime() - cleanStarted
                android.util.Log.i("DieterRecovery", "$codec continuous decode after FEC repair in $cleanElapsed ms")
                results.put(JSONObject().apply {
                    put("codec", codec)
                    put("decoder", media.decoderStatus?.implementation)
                    put("presentationEndpoint", session().render_measurement.name)
                    put("nativeFramesDecoded", host.stats.value.decodedFrames)
                    put("referenceRecoveries", session().reference_recoveries - before)
                    put("protectedRtpTimestamp", repaired)
                    put("decodedQuantizedRtpTimestamp", quantized)
                    // Includes the 16-frame continuity check / HTTP polling;
                    // neither value is an input-to-photon measurement.
                    put("postLossContinuityCheckMs", cleanElapsed)
                    put("fecProbeToObservedDecodeMs", proofElapsed)
                    put("fault", fault())
                })
                fault("none")
                val capture = captureScreenFixture()
                File(context.getExternalFilesDir(null), "screen-recovery-$codec.png").outputStream().use { capture.compress(Bitmap.CompressFormat.PNG, 100, it) }
            } finally {
                compose.runOnIdle { if (media.decodedOutputObserver === observer) media.decodedOutputObserver = previousObserver }
            }
        }
        try {
            compose.onNodeWithText("Codec test Mac").performClick()
            waitVideo("H264")
            // Keep loss qualification within the emulator decoder's sustained
            // throughput. Codec/high-refresh qualification is separate; every
            // frame here still uses native 1080p decoding for both codecs.
            compose.runOnIdle { host.selectMaxFps(15) }
            compose.waitUntil(10_000) { session().configuration?.max_fps == 15 }
            exercise("H264")
            val hevc = media.capabilities.hevcDecoder
            assertTrue("The selected hardware-accelerated test AVD must support HEVC", hevc)
            compose.onNodeWithContentDescription("Screen quality").performClick()
            compose.onNodeWithText("HEVC · up to 1080p60").performClick()
            exercise("H265")
            File(context.getExternalFilesDir(null), "screen-recovery.json").writeText(
                JSONObject().put("schemaVersion", 1).put("cases", results).toString())
        } finally {
            fault("none")
            compose.runOnIdle { host.close() }
            fixture.close()
        }
    }
}
