package com.dbpprt.dieter.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inspector.WindowInspector
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopControlRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.api.v1.RemoteDesktopRenderMeasurement
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.core.screens.ScreenChannels
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.ui.ScreenWorkspace
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import java.io.File
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.runBlocking
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Runs only with `just e2e run --suite screens` and its disposable native
 * service: the app's canvas, gestures, keyboard, clipboard, and the shared
 * core's session lifecycle and recovery over the real WebRTC engine.
 * No production credential or endpoint is read or replaced by this test.
 */
class ScreenEndToEndTest {
    @get:Rule val compose = createComposeRule()
    private var previousForceTURN: String? = null

    @org.junit.Before fun setFixtureTransportPolicy() {
        previousForceTURN = System.getProperty("dieter.test.forceTURN")
        System.setProperty("dieter.test.forceTURN", (InstrumentationRegistry.getArguments().getString("forceTURN") == "1").toString())
    }

    @org.junit.After fun restoreFixtureTransportPolicy() {
        previousForceTURN?.let { System.setProperty("dieter.test.forceTURN", it) }
            ?: System.clearProperty("dieter.test.forceTURN")
    }

    @Test fun nativeVideoCanvasGesturesKeyboardAndSessionLifecycle() {
        val arguments = InstrumentationRegistry.getArguments()
        val fixture = ScreenFixture.fromArguments()
        assumeTrue("Run just e2e run --suite screens for native screen integration", fixture != null)
        fixture!!
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val host = fixture.host(context) {
            lowLatencyDecoding = arguments.getString("screenLowLatency") != "0"
            surfacePresentation = arguments.getString("screenSurface") == "1"
            directSurfacePresentation = arguments.getString("screenDirectSurface") == "1"
        }
        lateinit var canvas: ScreenCanvasView
        fun view() = host.view.value
        fun state() = view().state ?: RemoteDesktopSessionState()
        fun failure() = (view().phase as? ScreenPhase.Failed)?.message
        fun streaming() = view().phase == ScreenPhase.Streaming
        fun settled() = streaming() || view().phase is ScreenPhase.Failed
        fun sent(label: String) = host.media.sentMessages(label)
        fun remoteInput() = sent(ScreenChannels.POINTER) + sent(ScreenChannels.INPUT)
        compose.setContent {
            DieterTheme {
                androidx.compose.material3.Scaffold { padding ->
                    ScreenWorkspace(listOf(MachineRow("d_screens_fixture", "Native test Mac", "isolated", daemonId = "d_screens_fixture")), padding, host) {}
                }
            }
        }
        fun findCanvas(view: View): ScreenCanvasView? {
            if (view is ScreenCanvasView) return view
            if (view is ViewGroup) for (index in 0 until view.childCount) findCanvas(view.getChildAt(index))?.let { return it }
            return null
        }
        fun connect() {
            if (compose.onAllNodesWithTag("screen-machine-d_screens_fixture").fetchSemanticsNodes().isNotEmpty())
                compose.onNodeWithTag("screen-machine-d_screens_fixture").performClick()
            else compose.onNodeWithTag("screen-connect").performClick()
            compose.waitForIdle()
            compose.runOnIdle { canvas = requireNotNull(WindowInspector.getGlobalWindowViews().firstNotNullOfOrNull(::findCanvas)) }
        }
        fun awaitInputAck(after: Long) {
            compose.runOnIdle { host.key(41, true); host.key(41, false) }
            compose.waitUntil(5_000) { state().last_input_ordinal > after }
        }
        try {
            connect()
            compose.waitUntil(45_000) { settled() }
            assertEquals(failure(), ScreenPhase.Streaming, view().phase)
            compose.waitUntil(10_000) { view().controlActive }
            compose.waitUntil(10_000) { host.stats.value.fps > 5 }
            assertTrue(state().width >= 640)
            // The first pointer move after a pause is sent at once; later ones coalesce.
            val pointerBefore = sent(ScreenChannels.POINTER)
            compose.runOnIdle { host.pointer(0.2, 0.2) }
            compose.waitUntil(1_000) { sent(ScreenChannels.POINTER) == pointerBefore + 1 }
            compose.runOnIdle {
                host.pointer(0.3, 0.3)
                host.releaseInput()
            }

            compose.onNodeWithContentDescription("Connection details").performClick()
            val clipboard = context.getSystemService(ClipboardManager::class.java)
            val originalClip = clipboard.primaryClip
            val (hostClient, hostHttp) = fixture.client()
            fun request(action: RemoteDesktopClipboardRequest.Action, value: String = "") = RemoteDesktopClipboardRequest(
                session_id = view().sessionId, control_generation = state().control_generation,
                operation_id = UUID.randomUUID().toString(), action = action, text = value,
            )
            fun awaitClipboard(before: Int, timeout: Long = 15_000) {
                compose.waitUntil(timeout) { view().clipboardOperations > before || (!view().clipboardBusy && view().clipboardError != null) }
                assertNull(view().clipboardError)
            }
            try {
                val text = "Android clipboard é漢字🙂\n  keep whitespace\n"
                compose.runOnIdle { clipboard.setPrimaryClip(ClipData.newPlainText("Screen fixture", text)) }
                val pasted = view().clipboardOperations
                compose.onNodeWithTag("screens.clipboard.paste").performClick()
                awaitClipboard(pasted, 7_000)
                val copied = runBlocking { hostClient.ExchangeRemoteDesktopClipboard().execute(request(RemoteDesktopClipboardRequest.Action.READ)) }
                assertEquals(text, copied.text)
                val binary = ByteArray(2 * 1024 * 1024) { (it % 253).toByte() }
                val png = Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCWQAAAAASUVORK5CYII=")
                for (image in listOf(true, false)) {
                    val item = RemoteDesktopClipboardItem(
                        name = if (image) "pixel.png" else "payload.bin", mime_type = if (image) "image/png" else "application/octet-stream",
                        kind = if (image) RemoteDesktopClipboardItem.Kind.IMAGE else RemoteDesktopClipboardItem.Kind.FILE,
                        data_ = (if (image) png else binary).toByteString(),
                    )
                    val items = if (image) listOf(item) else listOf(item, RemoteDesktopClipboardItem(name = "empty.txt", mime_type = "text/plain"))
                    // Stage the files exactly as a remote copy would, then paste them back.
                    compose.runOnIdle { AndroidClipboard(context).apply("", items) }
                    val before = view().clipboardOperations
                    compose.onNodeWithTag("screens.clipboard.paste").performClick()
                    awaitClipboard(before)
                    val received = runBlocking {
                        hostClient.ExchangeRemoteDesktopClipboard().execute(request(RemoteDesktopClipboardRequest.Action.READ).copy(accept_binary = true))
                    }
                    assertArrayEquals(if (image) png else binary, received.items.first().data_.toByteArray())
                    if (!image) {
                        assertEquals(2, received.items.size)
                        assertEquals(0, received.items[1].data_.size)
                    }
                    compose.runOnIdle { clipboard.clearPrimaryClip() }
                    val copyBefore = view().clipboardOperations
                    compose.onNodeWithTag("screens.clipboard.copy").performClick()
                    awaitClipboard(copyBefore)
                    val local = requireNotNull(clipboard.primaryClip)
                    assertEquals(if (image) 1 else 2, local.itemCount)
                    assertArrayEquals(if (image) png else binary, context.contentResolver.openInputStream(requireNotNull(local.getItemAt(0).uri))!!.use { it.readBytes() })
                }
                val remoteText = "Remote host → Android clipboard 🦊"
                runBlocking { hostClient.ExchangeRemoteDesktopClipboard().execute(request(RemoteDesktopClipboardRequest.Action.WRITE, remoteText)) }
                compose.waitUntil(7_000) { clipboard.primaryClip?.getItemAt(0)?.text?.toString() == remoteText }
                compose.onNodeWithTag("screens.clipboard.toggle").performClick()
                compose.waitUntil(5_000) { !view().clipboardEnabled }
                runBlocking {
                    try {
                        hostClient.ExchangeRemoteDesktopClipboard().execute(request(RemoteDesktopClipboardRequest.Action.READ))
                        fail("Disabled sharing accepted clipboard read")
                    } catch (_: GrpcException) {
                    }
                }
                compose.onNodeWithTag("screens.clipboard.toggle").performClick()
                compose.waitUntil(5_000) { view().clipboardEnabled }
                assertTrue(view().controlActive)
            } finally {
                hostHttp.connectionPool.evictAll()
                compose.runOnIdle { if (originalClip != null) clipboard.setPrimaryClip(originalClip) else clipboard.clearPrimaryClip() }
            }
            if (fixture.multi) {
                compose.waitUntil(10_000) { state().connected_clients >= 2 }
                val (client, http) = fixture.client()
                try {
                    val peers = runBlocking { client.ListRemoteDesktopSessions().execute(Unit) }
                    val mac = peers.sessions.first { it.client_name == "Mac" }
                    assertEquals(1, peers.capture_streams)
                    assertTrue(peers.encoders in 1..2)
                    // Hold a key, then transfer via the same authenticated API the UI uses.
                    // The owned target receives its release before the new grant.
                    compose.runOnIdle { host.key(4, true) }
                    runBlocking { client.SetRemoteDesktopControl().execute(RemoteDesktopControlRequest(session_id = mac.session_id, take_control = true)) }
                    compose.waitUntil(10_000) { !state().control_active && !view().controlActive }
                    compose.waitUntil(10_000) { state().controller_name.isEmpty() }
                    compose.onNodeWithTag("screens.control").performClick()
                    compose.waitUntil(10_000) { view().controlActive }
                    // Both controls in the Android toolbar exercise real daemon grants.
                    compose.onNodeWithTag("screens.control").performClick()
                    compose.waitUntil(10_000) { !state().control_active }
                    compose.onNodeWithTag("screens.control").performClick()
                    compose.waitUntil(10_000) { view().controlActive }
                } finally {
                    http.connectionPool.evictAll()
                }
            }

            compose.onNodeWithText("Done").performClick()
            // Capture the actual GPU output, not only a composable placeholder.
            val screenshot = captureScreenFixture()
            val samples = mutableSetOf<Int>()
            for (x in 0 until screenshot.width step 37) for (y in 0 until screenshot.height step 37) samples.add(screenshot.getPixel(x, y))
            if (fixture.real) assertTrue("Video should contain actual screen pixels", samples.size > 50)
            else {
                SystemClock.sleep(350)
                val next = captureScreenFixture()
                assertNotEquals("Synthetic luminance must visibly advance", screenshot.getPixel(screenshot.width / 2 + 80, screenshot.height / 2),
                    next.getPixel(next.width / 2 + 80, next.height / 2))
            }
            File(context.getExternalFilesDir(null), "screen-e2e.png").outputStream().use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) }

            // Put the cursor inside the owned native target. Gesture positions are deliberately
            // elsewhere on Android: a touch must move this cursor relatively, never teleport it.
            compose.runOnIdle {
                canvas.canvasModel.setCursor(fixture.double("targetX"), fixture.double("targetY"))
                host.pointer(canvas.canvasModel.cursor.x, canvas.canvasModel.cursor.y)
            }
            SystemClock.sleep(100)
            val startX = canvas.canvasModel.cursor.x
            val startY = canvas.canvasModel.cursor.y
            val cx = canvas.width * .5f; val cy = canvas.height * .55f
            val travel = android.view.ViewConfiguration.get(canvas.context).scaledTouchSlop * 1.5f
            gesture(canvas, listOf(listOf(cx to cy), listOf(cx + travel / 2 to cy + travel / 2), listOf(cx + travel to cy + travel)))
            assertTrue("Relative X: $startX -> ${canvas.canvasModel.cursor.x}; canvas ${canvas.width}x${canvas.height}, scale ${canvas.canvasModel.scale}",
                canvas.canvasModel.cursor.x > startX && canvas.canvasModel.cursor.x < startX + .1)
            assertTrue(canvas.canvasModel.cursor.y > startY && canvas.canvasModel.cursor.y < startY + .1)
            gesture(canvas, listOf(listOf(40f to 100f), listOf(40f to 100f)))
            gesture(canvas, listOf(listOf(cx to cy), listOf(cx + 8 to cy + 8)), holdStartMillis = 600)
            SystemClock.sleep(200)
            compose.runOnIdle {
                val ime = canvas.onCreateInputConnection(EditorInfo())
                ime.setComposingText("temporary", 1)
                ime.commitText("Android écran 世界", 1)
                ime.finishComposingText()
                canvas.pressKey(43); canvas.pressKey(80)
            }
            compose.waitUntil(15_000) { view().controlActive && canvas.hasWindowFocus() }
            val beforeKeys = listOf(canvas.width, canvas.height)
            compose.onNodeWithContentDescription("Special keys").performClick()
            compose.runOnIdle { assertEquals(beforeKeys, listOf(canvas.width, canvas.height)) }
            compose.onNodeWithText("Ctrl").performClick()
            compose.onNodeWithText("Ctrl").performClick()
            compose.onNodeWithText("Esc").performClick()
            val keyboardGeometry = listOf(canvas.width.toDouble(), canvas.height.toDouble(), canvas.canvasModel.scale)
            compose.onNodeWithContentDescription("Show keyboard").performClick()
            compose.waitUntil(5_000) { androidx.core.view.ViewCompat.getRootWindowInsets(canvas)?.isVisible(androidx.core.view.WindowInsetsCompat.Type.ime()) == true }
            compose.runOnIdle {
                assertEquals(keyboardGeometry, listOf(canvas.width.toDouble(), canvas.height.toDouble(), canvas.canvasModel.scale))
                canvas.onCreateInputConnection(EditorInfo()).commitText("\n", 1)
            }
            compose.onNodeWithContentDescription("Hide keyboard").performClick()
            // Wait for the IME window transition before dispatching remote gestures.
            compose.waitUntil(15_000) { view().controlActive && canvas.hasWindowFocus() }
            // Two fingers change only the local canvas; they must never generate mouse input.
            SystemClock.sleep(200)
            val inputBeforeZoom = remoteInput()
            val configurationsBeforeZoom = fixture.configurations.get()
            compose.runOnIdle { canvas.resetCanvas() }
            fun canvasEvidence(name: String) {
                SystemClock.sleep(80)
                val bitmap = captureScreenFixture()
                File(context.getExternalFilesDir(null), "screen-canvas-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            val gx = canvas.width * .5f; val gy = canvas.height * .5f
            canvasEvidence("fit")
            val fitLeft = canvas.canvasModel.left; val fitTop = canvas.canvasModel.top
            gesture(canvas, listOf(listOf(gx - 70 to gy, gx + 70 to gy), listOf(gx - 10 to gy + 80, gx + 130 to gy + 80)))
            canvasEvidence("pan")
            assertEquals("Fit must allow horizontal canvas movement", fitLeft + 60, canvas.canvasModel.left, .1)
            assertEquals("Letterboxing must not lock vertical panning", fitTop + 80, canvas.canvasModel.top, .1)

            val anchorX = (gx - canvas.canvasModel.left) / (canvas.canvasModel.remoteWidth * canvas.canvasModel.scale)
            val anchorY = (gy - canvas.canvasModel.top) / (canvas.canvasModel.remoteHeight * canvas.canvasModel.scale)
            gesture(canvas, listOf(listOf(gx - 100 to gy, gx + 100 to gy), listOf(gx - 60 to gy + 30, gx + 100 to gy + 30)))
            assertEquals(.8, canvas.canvasModel.zoom, .001)
            assertEquals(gx + 20.0, canvas.canvasModel.left + anchorX * canvas.canvasModel.remoteWidth * canvas.canvasModel.scale, .1)
            assertEquals(gy + 30.0, canvas.canvasModel.top + anchorY * canvas.canvasModel.remoteHeight * canvas.canvasModel.scale, .1)
            canvasEvidence("pinch")

            val continuous = (0..12).map { step ->
                val radius = 70f * Math.pow(1.017, step.toDouble()).toFloat()
                listOf(gx + step * 2 - radius to gy + step * 3, gx + step * 2 + radius to gy + step * 3)
            }
            gesture(canvas, continuous)
            assertEquals(.8 * Math.pow(1.017, 12.0), canvas.canvasModel.zoom, .001)
            val recontactLeft = canvas.canvasModel.left; val recontactTop = canvas.canvasModel.top
            // Keep one finger down while lifting/replacing the other: rebase
            // the pinch without turning the remaining finger into mouse input.
            gesture(canvas, listOf(listOf(gx - 70 to gy, gx + 70 to gy),
                listOf(gx - 55 to gy + 20, gx + 85 to gy + 20),
                listOf(gx - 55 to gy + 20),
                listOf(gx - 55 to gy + 20, gx + 85 to gy + 20),
                listOf(gx - 30 to gy + 50, gx + 110 to gy + 50)))
            assertEquals(recontactLeft + 40, canvas.canvasModel.left, .1)
            assertEquals(recontactTop + 50, canvas.canvasModel.top, .1)
            assertEquals(configurationsBeforeZoom, fixture.configurations.get())
            assertEquals("Local zoom and pan must not send remote input", inputBeforeZoom, remoteInput())
            compose.runOnIdle { canvas.resetCanvas() }
            gesture(canvas, listOf(listOf(cx - 70 to cy, cx + 70 to cy), listOf(cx - 120 to cy + 30, cx + 120 to cy + 30)))
            assertTrue(canvas.canvasModel.zoom > 1.4)
            assertEquals(inputBeforeZoom, remoteInput())
            // Three fingers create a bounded remote scroll gesture, not a zoom or click.
            val zoom = canvas.canvasModel.zoom
            gesture(canvas, listOf(listOf(cx - 80 to cy, cx to cy, cx + 80 to cy), listOf(cx - 80 to cy + 60, cx to cy + 60, cx + 80 to cy + 60)))
            assertEquals(zoom, canvas.canvasModel.zoom, 0.0)
            if (fixture.real) {
                compose.onNodeWithContentDescription("Connection details").performClick()
                val originalClip = clipboard.primaryClip
                try {
                    val beforeCopy = view().clipboardOperations
                    compose.onNodeWithTag("screens.clipboard.copy").performClick()
                    awaitClipboard(beforeCopy, 7_000)
                    assertTrue(clipboard.primaryClip?.getItemAt(0)?.text?.toString()?.contains("Android écran 世界") == true)
                    compose.runOnIdle { clipboard.setPrimaryClip(ClipData.newPlainText("Fixture paste", "Android native paste marker")) }
                    val beforePaste = view().clipboardOperations
                    compose.onNodeWithTag("screens.clipboard.paste").performClick()
                    awaitClipboard(beforePaste, 7_000)
                } finally {
                    compose.runOnIdle { if (originalClip != null) clipboard.setPrimaryClip(originalClip) else clipboard.clearPrimaryClip() }
                }
                compose.onNodeWithText("Done").performClick()
            }
            // Held keys are released when focus is lost and control stays disabled until restored.
            val ackBeforeFocus = state().last_input_ordinal
            compose.runOnIdle { host.key(4, true); host.focus(false) }
            compose.waitUntil(5_000) { !view().controlActive }
            SystemClock.sleep(300)
            compose.runOnIdle { host.focus(true); canvas.resetCanvas() }
            assertEquals(1.0, canvas.canvasModel.zoom, 0.0)
            compose.waitUntil(5_000) { view().controlActive }
            awaitInputAck(ackBeforeFocus)
            compose.runOnIdle {
                host.selectQuality(RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION)
                host.selectMaxFps(120)
                host.refresh()
            }
            compose.waitUntil(10_000) { state().configuration?.max_fps == 120 }
            assertTrue((state().configuration?.max_width ?: 0) <= 1920)
            compose.runOnIdle { host.selectMaxFps(60) }
            compose.waitUntil(10_000) { state().configuration?.max_fps == 60 }
            compose.waitUntil(10_000) { state().configuration?.quality == RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION }
            val displays = view().capabilities?.displays.orEmpty()
            if (displays.size > 1) {
                val primary = state().display_id
                val secondary = displays.first { it.id != primary }.id
                val generation = state().display_generation
                compose.runOnIdle { host.selectDisplay(secondary) }
                compose.waitUntil(15_000) { state().display_id == secondary && view().controlActive }
                assertTrue(state().display_generation > generation)
                compose.runOnIdle { host.selectDisplay(primary) }
                compose.waitUntil(15_000) { state().display_id == primary && view().controlActive }
            }
            val measuredEndpoint = if (host.media.directSurfacePresentation) RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED
                else RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED
            compose.waitUntil(5_000) { state().render_measurement == measuredEndpoint && host.stats.value.decodedFrames > 0 }
            if (arguments.getString("forceTURN") == "1") assertEquals("Relayed media", host.stats.value.route)
            val decoder = host.media.decoderStatus
            File(context.getExternalFilesDir(null), "screen-e2e-stats.json").writeText(JSONObject(mapOf(
                "schemaVersion" to 1, "sessionId" to view().sessionId, "nativeFramesDecoded" to host.stats.value.decodedFrames,
                "width" to state().width, "height" to state().height,
                "fps" to host.stats.value.fps, "inputAck" to state().last_input_ordinal,
                "mediaRoute" to host.stats.value.route,
                "encodeMs" to state().encode_ms, "captureToSendMs" to state().capture_to_send_ms,
                "jitterBufferMs" to state().jitter_buffer_ms,
                "renderMs" to state().render_ms,
                "renderEndpoint" to state().render_measurement.name,
                "decoder" to decoder?.implementation,
                "decoderHardware" to decoder?.hardware,
                "decoderLowLatencyAccepted" to decoder?.lowLatencyAccepted,
            )).toString())
            compose.onNodeWithTag("screen-disconnect").performClick()
            compose.waitUntil(5_000) { view().phase == ScreenPhase.Idle }
            // Drive Compose's test clock through the phase change and canvas-clear effect.
            compose.onNodeWithTag("screen-machines").assertIsDisplayed()
            compose.waitForIdle()
            SystemClock.sleep(200)
            compose.onNodeWithTag("screen-canvas").assertDoesNotExist()
            assertNull("Disconnect must detach the video renderer", host.media.videoSink)
            connect()
            compose.waitUntil(30_000) { settled() }
            assertEquals(failure(), ScreenPhase.Streaming, view().phase)
            compose.waitUntil(10_000) { view().controlActive }

            // NOT_FOUND and a broken route must create a new signed session/peer, not reuse
            // the old offer or leave Retry pointing at an obsolete connection.
            for (status in listOf(GrpcStatus.NOT_FOUND, GrpcStatus.UNAVAILABLE)) {
                val oldId = view().sessionId
                val oldRoutes = fixture.routesOpened.get()
                fixture.nextConfigurationFailure.set(status)
                compose.runOnIdle { host.refresh() }
                compose.waitUntil(30_000) { (view().sessionId.isNotEmpty() && view().sessionId != oldId && view().controlActive) || view().phase is ScreenPhase.Failed }
                assertEquals(failure(), ScreenPhase.Streaming, view().phase)
                assertNotEquals(oldId, view().sessionId)
                assertTrue("Recovery must discover and authenticate a fresh route", fixture.routesOpened.get() > oldRoutes)
                assertEquals(RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION, state().configuration?.quality)
                awaitInputAck(0)
            }

            // Also expire the actual daemon-side session. Its close signal and the peer
            // disconnect can race; only one replacement is allowed and input must resume.
            fixture.unavailableRoutes.set(5)
            val expiredId = view().sessionId
            assertEquals(204, fixture.control("expire-screen?session=$expiredId"))
            compose.waitUntil(30_000) { (view().sessionId.isNotEmpty() && view().sessionId != expiredId && view().controlActive) || view().phase is ScreenPhase.Failed }
            assertEquals(failure(), ScreenPhase.Streaming, view().phase)
            assertNotEquals(expiredId, view().sessionId)

            val beforeResume = view().sessionId
            compose.runOnIdle { host.focus(false); host.resume() }
            compose.waitUntil(30_000) { view().sessionId.isNotEmpty() && view().sessionId != beforeResume && view().controlActive }
            assertEquals(ScreenPhase.Streaming, view().phase)
            // A user disconnect during backoff cancels recovery, even after its timer fires.
            compose.onNodeWithTag("screen-disconnect").performClick()
            connect()
            compose.waitUntil(30_000) { view().controlActive }
            if (!fixture.real && !fixture.multi) {
                val oldCaptureId = view().sessionId
                val oldCaptureRoutes = fixture.routesOpened.get()
                assertEquals(204, fixture.control("stop-capture"))
                compose.waitUntil(30_000) { (view().sessionId.isNotEmpty() && view().sessionId != oldCaptureId && view().controlActive) || view().phase is ScreenPhase.Failed }
                assertEquals(failure(), ScreenPhase.Streaming, view().phase)
                assertNotEquals(oldCaptureId, view().sessionId)
                assertEquals("One helper failure must open exactly one new route", oldCaptureRoutes + 1, fixture.routesOpened.get())
                awaitInputAck(0)
            }
            fixture.nextConfigurationFailure.set(GrpcStatus.NOT_FOUND)
            compose.runOnIdle { host.refresh() }
            compose.waitUntil(5_000) { view().phase is ScreenPhase.Reconnecting }
            compose.runOnIdle { host.disconnect() }
            compose.waitUntil(5_000) { view().phase == ScreenPhase.Idle }
            val stoppedRoutes = fixture.routesOpened.get()
            SystemClock.sleep(4_500)
            assertEquals(ScreenPhase.Idle, view().phase)
            assertEquals(stoppedRoutes, fixture.routesOpened.get())

            // Repeated immediate disconnect/connect exercises completion of the old Close RPC.
            repeat(3) {
                connect()
                compose.waitUntil(30_000) { view().controlActive || view().phase is ScreenPhase.Failed }
                assertEquals(failure(), ScreenPhase.Streaming, view().phase)
                if (it < 2) compose.onNodeWithTag("screen-disconnect").performClick()
            }
        } catch (failure: Throwable) {
            runCatching {
                val capture = captureScreenFixture()
                File(context.getExternalFilesDir(null), "screen-failure.png").outputStream().use { capture.compress(Bitmap.CompressFormat.PNG, 100, it) }
                capture.recycle()
            }.onFailure { failure.addSuppressed(it) }
            throw AssertionError("Screen view: ${view().copy(cursorImage = null)}; pointer=${sent(ScreenChannels.POINTER)}; window focus=${canvas.hasWindowFocus()}", failure)
        } finally {
            compose.runOnIdle { canvas.release(); host.close() }
            fixture.close()
        }
    }

    private fun gesture(view: ScreenCanvasView, frames: List<List<Pair<Float, Float>>>, holdStartMillis: Long = 0) {
        val down = SystemClock.uptimeMillis()
        var time = down
        fun dispatch(action: Int, points: List<Pair<Float, Float>>) {
            val properties = Array(points.size) { index -> MotionEvent.PointerProperties().apply { id = index; toolType = MotionEvent.TOOL_TYPE_FINGER } }
            val coordinates = Array(points.size) { index -> MotionEvent.PointerCoords().apply { x = points[index].first; y = points[index].second; pressure = 1f; size = 1f } }
            time = maxOf(time + 20, SystemClock.uptimeMillis())
            val event = MotionEvent.obtain(down, time, action, points.size, properties, coordinates, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            compose.runOnIdle { assertTrue(view.dispatchTouchEvent(event)) }; event.recycle()
        }
        dispatch(MotionEvent.ACTION_DOWN, frames.first().take(1))
        if (holdStartMillis > 0) SystemClock.sleep(holdStartMillis)
        for (count in 2..frames.first().size) dispatch(MotionEvent.ACTION_POINTER_DOWN or ((count - 1) shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), frames.first().take(count))
        var previous = frames.first()
        frames.drop(1).forEach { points ->
            for (count in previous.size downTo points.size + 1) {
                dispatch(MotionEvent.ACTION_POINTER_UP or ((count - 1) shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), previous.take(count))
            }
            for (count in previous.size + 1..points.size) {
                dispatch(MotionEvent.ACTION_POINTER_DOWN or ((count - 1) shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), points.take(count))
            }
            dispatch(MotionEvent.ACTION_MOVE, points)
            previous = points
        }
        for (count in frames.last().size downTo 2) dispatch(MotionEvent.ACTION_POINTER_UP or ((count - 1) shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), frames.last().take(count))
        dispatch(MotionEvent.ACTION_UP, frames.last().take(1))
    }
}
