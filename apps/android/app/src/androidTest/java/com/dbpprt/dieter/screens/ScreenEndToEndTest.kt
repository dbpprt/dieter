package com.dbpprt.dieter.screens

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.inspector.WindowInspector
import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.test.*
import com.dbpprt.dieter.ui.ScreenWorkspace
import com.dbpprt.dieter.connection.EndpointConnection
import android.view.InputDevice
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.DieterServiceGrpcKt
import com.dbpprt.dieter.v1.RemoteDesktopQuality
import io.grpc.Metadata
import io.grpc.CallOptions
import io.grpc.Channel
import io.grpc.ClientCall
import io.grpc.ClientInterceptor
import io.grpc.MethodDescriptor
import io.grpc.Status
import io.grpc.okhttp.OkHttpChannelBuilder
import io.grpc.stub.MetadataUtils
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.Base64
import java.util.concurrent.atomic.AtomicReference

/** Runs only with scripts/test-android-screens.sh's disposable native service.
 * No production credential or endpoint is read or replaced by this test.
 */
class ScreenEndToEndTest {
    @get:Rule val compose = createComposeRule()

    @Test fun nativeVideoCanvasGesturesKeyboardAndSessionLifecycle() {
        val arguments = InstrumentationRegistry.getArguments()
        val encoded = arguments.getString("screenFixture")
        assumeTrue("Run scripts/test-android-screens.sh for native screen integration", encoded != null)
        val fixture = JSONObject(String(Base64.getDecoder().decode(encoded)))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        lateinit var controller: ScreenController
        lateinit var canvas: ScreenCanvasView
        val opened = java.util.concurrent.atomic.AtomicInteger()
        val configurations = java.util.concurrent.atomic.AtomicInteger()
        val unavailableRoutes = java.util.concurrent.atomic.AtomicInteger()
        val nextConfigurationFailure = AtomicReference<Status?>()
        val faults = object : ClientInterceptor {
            override fun <ReqT : Any?, RespT : Any?> interceptCall(method: MethodDescriptor<ReqT, RespT>, options: CallOptions, next: Channel): ClientCall<ReqT, RespT> {
                if (method.bareMethodName == "UpdateRemoteDesktopSession") configurations.incrementAndGet()
                val failure = if (method.bareMethodName == "UpdateRemoteDesktopSession") nextConfigurationFailure.getAndSet(null) else null
                if (failure == null) return next.newCall(method, options)
                return object : ClientCall<ReqT, RespT>() {
                    override fun start(listener: Listener<RespT>, headers: Metadata) { listener.onClose(failure, Metadata()) }
                    override fun request(count: Int) = Unit
                    override fun cancel(message: String?, cause: Throwable?) = Unit
                    override fun halfClose() = Unit
                    override fun sendMessage(message: ReqT) = Unit
                }
            }
        }
        suspend fun open(): ScreenConnection {
            if (unavailableRoutes.getAndUpdate { maxOf(0, it - 1) } > 0) throw Status.UNAVAILABLE.withDescription("Injected sleeping laptop network").asException()
            val channel = OkHttpChannelBuilder.forAddress("127.0.0.1", fixture.getInt("port")).usePlaintext().build()
            val headers = Metadata().apply { put(Metadata.Key.of("authorization", Metadata.ASCII_STRING_MARSHALLER), "Bearer ${fixture.getString("token")}") }
            return ScreenConnection(DieterServiceGrpcKt.DieterServiceCoroutineStub(channel).withInterceptors(MetadataUtils.newAttachHeadersInterceptor(headers), faults),
                Base64.getDecoder().decode(fixture.getString("certificate")), RTCConfiguration.parseFrom(Base64.getDecoder().decode(fixture.getString("rtc"))), "Isolated native fixture", if (opened.incrementAndGet() == 1) System.currentTimeMillis() + 3000 else null) { channel.shutdownNow() }
        }
        compose.setContent {
            controller = androidx.compose.runtime.remember { ScreenController(context) }
            DieterTheme {
                androidx.compose.material3.Scaffold { padding ->
                    ScreenWorkspace(listOf(EndpointConnection("fixture", "Native test Mac", "isolated", daemonId = "d_screens_fixture")),
                        padding, controller) { open() }
                }
            }
        }
        compose.onNodeWithTag("screen-machine").performClick()
        compose.onNodeWithText("Native test Mac").performClick()
        fun findCanvas(view: View): ScreenCanvasView? {
            if (view is ScreenCanvasView) return view
            if (view is ViewGroup) for (index in 0 until view.childCount) findCanvas(view.getChildAt(index))?.let { return it }
            return null
        }
        compose.runOnIdle { canvas = requireNotNull(WindowInspector.getGlobalWindowViews().firstNotNullOfOrNull(::findCanvas)) }
        fun connect() { compose.onNodeWithTag("screen-connect").performClick() }
        try {
            connect()
            compose.waitUntil(45_000) { controller.state.value.phase == "streaming" || controller.state.value.phase == "failed" }
            assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
            compose.waitUntil(10_000) { controller.state.value.control }
            compose.waitUntil(15_000) { opened.get() >= 2 && controller.state.value.control }
            compose.waitUntil(10_000) { controller.state.value.receivedFps > 5 }
            assertTrue(controller.state.value.session.width >= 640)
            compose.runOnIdle {
                val before = controller.pointerSequence
                controller.pointer(0.2f, 0.2f)
                assertEquals("First pointer movement must dispatch immediately", before + 1, controller.pointerSequence)
                controller.pointer(0.3f, 0.3f)
                controller.releaseInput()
            }
            val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            val originalClip = clipboard.primaryClip
            val clipboardRoute = kotlinx.coroutines.runBlocking { open() }
            try {
                val text = "Android clipboard é漢字🙂\n  keep whitespace\n"
                compose.runOnIdle { clipboard.setPrimaryClip(android.content.ClipData.newPlainText("Screen fixture", text)) }
                val completed = controller.clipboard.completedOperations
                compose.onNodeWithTag("screens.clipboard.paste").performClick()
                compose.waitUntil(7000) { controller.clipboard.completedOperations > completed || controller.state.value.clipboardError.isNotEmpty() }
                assertEquals("", controller.state.value.clipboardError)
                fun request(action: com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.Action, value: String = "") =
                    com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.newBuilder().setSessionId(controller.id)
                        .setControlGeneration(controller.state.value.session.controlGeneration).setOperationId(java.util.UUID.randomUUID().toString())
                        .setAction(action).setText(value).build()
                val copied = kotlinx.coroutines.runBlocking { clipboardRoute.rpc.exchangeRemoteDesktopClipboard(request(com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.Action.READ)) }
                assertEquals(text, copied.text)
                val binary = ByteArray(2 * 1024 * 1024) { (it % 253).toByte() }
                val png = Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCWQAAAAASUVORK5CYII=")
                for (image in listOf(true, false)) {
                    val item = com.dbpprt.dieter.v1.RemoteDesktopClipboardItem.newBuilder()
                        .setName(if (image) "pixel.png" else "payload.bin")
                        .setMimeType(if (image) "image/png" else "application/octet-stream")
                        .setKind(if (image) com.dbpprt.dieter.v1.RemoteDesktopClipboardItem.Kind.IMAGE else com.dbpprt.dieter.v1.RemoteDesktopClipboardItem.Kind.FILE)
                        .setData(com.google.protobuf.ByteString.copyFrom(if (image) png else binary)).build()
                    val items = if (image) listOf(item) else listOf(item, com.dbpprt.dieter.v1.RemoteDesktopClipboardItem.newBuilder().setName("empty.txt").setMimeType("text/plain").build())
                    val clip = requireNotNull(ScreenClipboardContent(items = items).clip(context))
                    compose.runOnIdle { clipboard.setPrimaryClip(clip) }
                    val before = controller.clipboard.completedOperations
                    compose.onNodeWithTag("screens.clipboard.paste").performClick()
                    compose.waitUntil(15_000) { controller.clipboard.completedOperations > before || controller.state.value.clipboardError.isNotEmpty() }
                    assertEquals("", controller.state.value.clipboardError)
                    val received = kotlinx.coroutines.runBlocking { clipboardRoute.rpc.exchangeRemoteDesktopClipboard(request(com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.Action.READ).toBuilder().setAcceptBinary(true).build()) }
                    assertArrayEquals(if (image) png else binary, received.itemsList.first().data.toByteArray())
                    if (!image) { assertEquals(2, received.itemsCount); assertEquals(0, received.itemsList[1].data.size()) }
                    compose.runOnIdle { controller.clipboard.enabled = false; clipboard.clearPrimaryClip(); controller.clipboard.enabled = true }
                    val copyBefore = controller.clipboard.completedOperations
                    compose.onNodeWithTag("screens.clipboard.copy").performClick()
                    compose.waitUntil(15_000) { controller.clipboard.completedOperations > copyBefore || controller.state.value.clipboardError.isNotEmpty() }
                    assertEquals("", controller.state.value.clipboardError)
                    val local = requireNotNull(clipboard.primaryClip)
                    assertEquals(if (image) 1 else 2, local.itemCount)
                    assertArrayEquals(if (image) png else binary, context.contentResolver.openInputStream(requireNotNull(local.getItemAt(0).uri))!!.use { it.readBytes() })
                }
                val remoteText = "Remote host → Android clipboard 🦊"
                kotlinx.coroutines.runBlocking { clipboardRoute.rpc.exchangeRemoteDesktopClipboard(request(com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.Action.WRITE, remoteText)) }
                compose.waitUntil(7000) { clipboard.primaryClip?.getItemAt(0)?.text?.toString() == remoteText }
                val large = "x".repeat(1024 * 1024)
                val result = kotlinx.coroutines.runBlocking { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                    controller.clipboard.exchange(com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.Action.WRITE, large)
                } }
                assertEquals("", result.error)
                // Clear the large host payload before Android's system clipboard observes it.
                kotlinx.coroutines.runBlocking { clipboardRoute.rpc.exchangeRemoteDesktopClipboard(request(com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.Action.WRITE, remoteText)) }
                compose.onNodeWithTag("screens.clipboard.toggle").performClick()
                SystemClock.sleep(400)
                kotlinx.coroutines.runBlocking {
                    try { clipboardRoute.rpc.exchangeRemoteDesktopClipboard(request(com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.Action.READ)); fail("Disabled sharing accepted clipboard read") }
                    catch (_: io.grpc.StatusException) { }
                }
                compose.onNodeWithTag("screens.clipboard.toggle").performClick()
                SystemClock.sleep(400)
                assertTrue(controller.state.value.control)
            } finally {
                clipboardRoute.close()
                compose.runOnIdle { if (originalClip != null) clipboard.setPrimaryClip(originalClip) else clipboard.clearPrimaryClip() }
            }
            if (fixture.optBoolean("multi")) {
                compose.waitUntil(10_000) { controller.state.value.session.connectedClients >= 2 }
                val route = kotlinx.coroutines.runBlocking { open() }
                try {
                    val peers = kotlinx.coroutines.runBlocking { route.rpc.listRemoteDesktopSessions(com.google.protobuf.Empty.getDefaultInstance()) }
                    val mac = peers.sessionsList.first { it.clientName == "Mac" }
                    assertEquals(1, peers.captureStreams)
                    assertTrue(peers.encoders in 1..2)
                    // Hold a key, then transfer via the same authenticated API the UI uses.
                    // The owned target receives its release before the new grant.
                    compose.runOnIdle { controller.key(4, true) }
                    kotlinx.coroutines.runBlocking { route.rpc.setRemoteDesktopControl(com.dbpprt.dieter.v1.RemoteDesktopControlRequest.newBuilder()
                        .setSessionId(mac.sessionId).setTakeControl(true).build()) }
                    compose.waitUntil(10_000) { !controller.state.value.session.controlActive && !controller.state.value.control }
                    compose.waitUntil(10_000) { controller.state.value.session.controllerName.isEmpty() }
                    compose.onNodeWithTag("screens.control").performClick()
                    compose.waitUntil(10_000) { controller.state.value.control }
                    // Both controls in the Android toolbar exercise real daemon grants.
                    compose.onNodeWithTag("screens.control").performClick()
                    compose.waitUntil(10_000) { !controller.state.value.session.controlActive }
                    compose.onNodeWithTag("screens.control").performClick()
                    compose.waitUntil(10_000) { controller.state.value.control }
                } finally { route.close() }
            }

            // Capture the actual GPU output, not only a composable placeholder.
            val screenshot = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            assertNotNull(screenshot)
            val samples = mutableSetOf<Int>()
            for (x in 0 until screenshot.width step 37) for (y in 0 until screenshot.height step 37) samples.add(screenshot.getPixel(x, y))
            if (fixture.getBoolean("real")) assertTrue("Video should contain actual screen pixels", samples.size > 50)
            else {
                SystemClock.sleep(350)
                val next = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                assertNotEquals("Synthetic luminance must visibly advance", screenshot.getPixel(screenshot.width / 2 + 80, screenshot.height / 2),
                    next.getPixel(next.width / 2 + 80, next.height / 2))
            }
            File(context.getExternalFilesDir(null), "screen-e2e.png").outputStream().use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) }

            // Put the cursor inside the owned native target. Gesture positions are deliberately
            // elsewhere on Android: a touch must move this cursor relatively, never teleport it.
            compose.runOnIdle {
                canvas.canvasModel.cursor(fixture.getDouble("targetX").toFloat(), fixture.getDouble("targetY").toFloat())
                controller.pointer(canvas.canvasModel.cursorX, canvas.canvasModel.cursorY)
            }
            SystemClock.sleep(100)
            val startX = canvas.canvasModel.cursorX
            val startY = canvas.canvasModel.cursorY
            val cx = canvas.width * .5f; val cy = canvas.height * .55f
            gesture(canvas, listOf(listOf(cx to cy), listOf(cx + 12 to cy + 10), listOf(cx + 24 to cy + 20)))
            assertTrue("Relative X: $startX -> ${canvas.canvasModel.cursorX}; canvas ${canvas.width}x${canvas.height}, scale ${canvas.canvasModel.scale}", canvas.canvasModel.cursorX > startX && canvas.canvasModel.cursorX < startX + .1)
            assertTrue(canvas.canvasModel.cursorY > startY && canvas.canvasModel.cursorY < startY + .1)
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
            compose.waitUntil(15_000) { controller.state.value.control && canvas.hasWindowFocus() }
            compose.onNodeWithContentDescription("Special keys").performClick()
            compose.onNodeWithText("Ctrl").performClick()
            compose.onNodeWithText("Ctrl").performClick()
            compose.onNodeWithText("Esc").performClick()
            compose.onNodeWithContentDescription("Toggle keyboard").performClick()
            SystemClock.sleep(400)
            compose.onNodeWithContentDescription("Toggle keyboard").performClick()
            // Wait for the IME window transition before dispatching remote gestures.
            compose.waitUntil(15_000) { controller.state.value.control && canvas.hasWindowFocus() }
            // Two fingers change only the local canvas; they must never generate mouse input.
            SystemClock.sleep(200)
            val beforeZoom = controller.lastPointerOrdinal
            val beforeCanvasConfigurations = configurations.get()
            compose.runOnIdle { canvas.resetCanvas() }
            fun canvasEvidence(name: String) {
                SystemClock.sleep(80)
                val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                File(context.getExternalFilesDir(null), "screen-canvas-$name.png").outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
            }
            val gx = canvas.width * .5f; val gy = canvas.height * .5f
            canvasEvidence("fit")
            val fitLeft = canvas.canvasModel.left; val fitTop = canvas.canvasModel.top
            gesture(canvas, listOf(listOf(gx - 70 to gy, gx + 70 to gy),
                listOf(gx - 10 to gy + 80, gx + 130 to gy + 80)))
            canvasEvidence("pan")
            assertEquals("Fit must allow horizontal canvas movement", fitLeft + 60, canvas.canvasModel.left, .1f)
            assertEquals("Letterboxing must not lock vertical panning", fitTop + 80, canvas.canvasModel.top, .1f)

            val anchorX = (gx - canvas.canvasModel.left) / (canvas.canvasModel.remoteWidth * canvas.canvasModel.scale)
            val anchorY = (gy - canvas.canvasModel.top) / (canvas.canvasModel.remoteHeight * canvas.canvasModel.scale)
            gesture(canvas, listOf(listOf(gx - 100 to gy, gx + 100 to gy),
                listOf(gx - 60 to gy + 30, gx + 100 to gy + 30)))
            assertEquals(.8f, canvas.canvasModel.zoom, .001f)
            assertEquals(gx + 20, canvas.canvasModel.left + anchorX * canvas.canvasModel.remoteWidth * canvas.canvasModel.scale, .1f)
            assertEquals(gy + 30, canvas.canvasModel.top + anchorY * canvas.canvasModel.remoteHeight * canvas.canvasModel.scale, .1f)
            canvasEvidence("pinch")

            val continuous = (0..12).map { step ->
                val radius = 70f * Math.pow(1.017, step.toDouble()).toFloat()
                listOf(gx + step * 2 - radius to gy + step * 3, gx + step * 2 + radius to gy + step * 3)
            }
            gesture(canvas, continuous)
            assertEquals(.8f * Math.pow(1.017, 12.0).toFloat(), canvas.canvasModel.zoom, .001f)
            val recontactLeft = canvas.canvasModel.left; val recontactTop = canvas.canvasModel.top
            // Keep one finger down while lifting/replacing the other: rebase
            // the pinch without turning the remaining finger into mouse input.
            gesture(canvas, listOf(listOf(gx - 70 to gy, gx + 70 to gy),
                listOf(gx - 55 to gy + 20, gx + 85 to gy + 20),
                listOf(gx - 55 to gy + 20),
                listOf(gx - 55 to gy + 20, gx + 85 to gy + 20),
                listOf(gx - 30 to gy + 50, gx + 110 to gy + 50)))
            assertEquals(recontactLeft + 40, canvas.canvasModel.left, .1f)
            assertEquals(recontactTop + 50, canvas.canvasModel.top, .1f)
            assertEquals(beforeCanvasConfigurations, configurations.get())
            assertEquals(beforeZoom, controller.lastPointerOrdinal)
            compose.runOnIdle { canvas.resetCanvas() }
            gesture(canvas, listOf(listOf(cx - 70 to cy, cx + 70 to cy), listOf(cx - 120 to cy + 30, cx + 120 to cy + 30)))
            assertTrue(canvas.canvasModel.zoom > 1.4f)
            assertEquals(beforeZoom, controller.lastPointerOrdinal)
            // Three fingers create a bounded remote scroll gesture, not a zoom or click.
            val zoom = canvas.canvasModel.zoom
            gesture(canvas, listOf(listOf(cx - 80 to cy, cx to cy, cx + 80 to cy),
                listOf(cx - 80 to cy + 60, cx to cy + 60, cx + 80 to cy + 60)))
            assertEquals(zoom, canvas.canvasModel.zoom, 0f)
            if (fixture.getBoolean("real")) {
                val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                val beforeCopy = controller.clipboard.completedOperations
                compose.onNodeWithTag("screens.clipboard.copy").performClick()
                compose.waitUntil(7000) { controller.clipboard.completedOperations > beforeCopy || controller.state.value.clipboardError.isNotEmpty() }
                assertEquals("", controller.state.value.clipboardError)
                assertTrue(clipboard.primaryClip?.getItemAt(0)?.text?.toString()?.contains("Android écran 世界") == true)
                compose.runOnIdle { clipboard.setPrimaryClip(android.content.ClipData.newPlainText("Fixture paste", "Android native paste marker")) }
                val beforePaste = controller.clipboard.completedOperations
                compose.onNodeWithTag("screens.clipboard.paste").performClick()
                compose.waitUntil(7000) { controller.clipboard.completedOperations > beforePaste || controller.state.value.clipboardError.isNotEmpty() }
                assertEquals("", controller.state.value.clipboardError)
            }
            // Held keys are released when focus is lost and control stays disabled until restored.
            compose.runOnIdle { controller.key(4, true); controller.focus(false) }
            assertFalse(controller.state.value.control)
            SystemClock.sleep(300)
            compose.runOnIdle { controller.focus(true); canvas.resetCanvas() }
            assertEquals(1f, canvas.canvasModel.zoom, 0f)
            compose.waitUntil(5000) { controller.state.value.control && controller.state.value.session.lastInputOrdinal > beforeZoom }
            compose.waitUntil(10_000) { opened.get() >= 2 && controller.state.value.control }
            compose.runOnIdle { controller.configure(quality = RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION, maxFPS = 120, refresh = true) }
            compose.waitUntil(10_000) { controller.state.value.session.configuration.maxFps == 120 }
            assertTrue(controller.state.value.session.configuration.maxWidth <= 1920)
            compose.runOnIdle { controller.configure(maxFPS = 60) }
            compose.waitUntil(10_000) { controller.state.value.session.configuration.maxFps == 60 }
            compose.waitUntil(10_000) { controller.state.value.session.configuration.quality == RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION }
            if (controller.state.value.capabilities.displaysCount > 1) {
                val primary = controller.state.value.session.displayId
                val secondary = controller.state.value.capabilities.displaysList.first { it.id != primary }.id
                val generation = controller.state.value.session.displayGeneration
                compose.runOnIdle { controller.configure(display = secondary) }
                compose.waitUntil(15_000) { controller.state.value.session.displayId == secondary && controller.state.value.control }
                assertTrue(controller.state.value.session.displayGeneration > generation)
                compose.runOnIdle { controller.configure(display = primary) }
                compose.waitUntil(15_000) { controller.state.value.session.displayId == primary && controller.state.value.control }
            }
            File(context.getExternalFilesDir(null), "screen-e2e-stats.json").writeText(JSONObject(mapOf(
                "width" to controller.state.value.session.width, "height" to controller.state.value.session.height,
                "fps" to controller.state.value.receivedFps, "inputAck" to controller.state.value.session.lastInputOrdinal,
                "encodeMs" to controller.state.value.session.encodeMs, "captureToSendMs" to controller.state.value.session.captureToSendMs,
                "jitterBufferMs" to controller.state.value.session.jitterBufferMs,
                "renderMs" to controller.state.value.session.renderMs,
            )).toString())
            compose.onNodeWithTag("screen-disconnect").performClick()
            assertEquals("idle", controller.state.value.phase)
            // Drive Compose's test clock through the phase change and canvas-clear effect.
            compose.onNodeWithTag("screen-connect").assertIsDisplayed()
            compose.waitForIdle()
            SystemClock.sleep(200)
            val cleared = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            assertEquals("Disconnect must clear remote pixels", android.graphics.Color.rgb(12, 15, 20),
                cleared.getPixel(cleared.width / 2, cleared.height / 2))
            connect()
            compose.waitUntil(30_000) { controller.state.value.phase == "streaming" || controller.state.value.phase == "failed" }
            assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
            compose.waitUntil(10000) { controller.state.value.control }

            // NOT_FOUND and a broken route must create a new signed session/peer, not reuse
            // the old offer or leave Retry pointing at an obsolete connection.
            for (failure in listOf(Status.NOT_FOUND.withDescription("remote desktop session not found"), Status.UNAVAILABLE)) {
                val oldId = controller.id
                val oldRoutes = opened.get()
                nextConfigurationFailure.set(failure)
                compose.runOnIdle { controller.configure(quality = RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION, refresh = true) }
                compose.waitUntil(30_000) { (controller.id != oldId && controller.state.value.control) || controller.state.value.phase == "failed" }
                assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
                assertNotEquals(oldId, controller.id)
                assertTrue("Recovery must discover and authenticate a fresh route", opened.get() > oldRoutes)
                assertEquals(RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION, controller.state.value.session.configuration.quality)
                compose.runOnIdle { controller.key(41, true); controller.key(41, false) }
                compose.waitUntil(5_000) { controller.state.value.session.lastInputOrdinal >= 2 }
            }

            // Also expire the actual daemon-side session. Its close signal and the peer
            // disconnect can race; only one replacement is allowed and input must resume.
            unavailableRoutes.set(5)
            val expiredId = controller.id
            val expiry = java.net.URL("http://127.0.0.1:${fixture.getInt("port")}/test/expire-screen?session=$expiredId").openConnection() as java.net.HttpURLConnection
            try {
                expiry.requestMethod = "POST"
                expiry.connectTimeout = 5_000; expiry.readTimeout = 5_000
                expiry.setRequestProperty("Authorization", "Bearer ${fixture.getString("token")}")
                assertEquals(204, expiry.responseCode)
            } finally { expiry.disconnect() }
            compose.waitUntil(30_000) { (controller.id != expiredId && controller.state.value.control) || controller.state.value.phase == "failed" }
            assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
            assertNotEquals(expiredId, controller.id)

            val beforeResume = controller.id
            compose.runOnIdle { controller.focus(false); controller.resumeConnection() }
            compose.waitUntil(30_000) { controller.id != beforeResume && controller.state.value.control }
            assertEquals("streaming", controller.state.value.phase)
            // A user disconnect during backoff cancels recovery, even after its timer fires.
            compose.onNodeWithTag("screen-disconnect").performClick()
            connect()
            compose.waitUntil(30_000) { controller.state.value.control }
            if (!fixture.optBoolean("real") && !fixture.optBoolean("multi")) {
                val oldCaptureId = controller.id
                val oldCaptureRoutes = opened.get()
                val stopCapture = java.net.URL("http://127.0.0.1:${fixture.getInt("port")}/test/stop-capture").openConnection() as java.net.HttpURLConnection
                try {
                    stopCapture.requestMethod = "POST"
                    stopCapture.connectTimeout = 5_000; stopCapture.readTimeout = 5_000
                    stopCapture.setRequestProperty("Authorization", "Bearer ${fixture.getString("token")}")
                    assertEquals(204, stopCapture.responseCode)
                } finally { stopCapture.disconnect() }
                compose.waitUntil(30_000) { (controller.id != oldCaptureId && controller.state.value.control) || controller.state.value.phase == "failed" }
                assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
                assertNotEquals(oldCaptureId, controller.id)
                assertEquals("One helper failure must open exactly one new route", oldCaptureRoutes + 1, opened.get())
                compose.runOnIdle { controller.key(41, true); controller.key(41, false) }
                compose.waitUntil(5_000) { controller.state.value.session.lastInputOrdinal >= 2 }
            }
            nextConfigurationFailure.set(Status.NOT_FOUND)
            compose.runOnIdle { controller.configure(refresh = true) }
            compose.waitUntil(5_000) { controller.state.value.phase == "reconnecting" }
            compose.runOnIdle { controller.disconnect() }
            val stoppedRoutes = opened.get()
            SystemClock.sleep(4_500)
            assertEquals("idle", controller.state.value.phase)
            assertEquals(stoppedRoutes, opened.get())

            // Repeated immediate disconnect/connect exercises completion of the old Close RPC.
            repeat(3) {
                connect()
                compose.waitUntil(30_000) { controller.state.value.control || controller.state.value.phase == "failed" }
                assertEquals(controller.state.value.error, "streaming", controller.state.value.phase)
                if (it < 2) compose.onNodeWithTag("screen-disconnect").performClick()
            }
        } catch (failure: Throwable) {
            val capture = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            File(context.getExternalFilesDir(null), "screen-failure.png").outputStream().use { capture?.compress(Bitmap.CompressFormat.PNG, 100, it) }
            throw AssertionError("Screen state: ${controller.state.value}; pointer ordinal=${controller.lastPointerOrdinal}; window focus=${canvas.hasWindowFocus()}", failure)
        } finally {
            compose.runOnIdle { canvas.release(); controller.close() }
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
