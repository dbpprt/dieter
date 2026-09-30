package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.test.*
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.screens.Point
import com.dbpprt.dieter.screens.ScreenCanvasView
import com.dbpprt.dieter.screens.ScreenHost
import com.dbpprt.dieter.sharedcore.SharedCore
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inspector.WindowInspector
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowCompat
import org.junit.Assert.*
import com.dbpprt.dieter.ui.theme.DieterTheme
import kotlinx.coroutines.awaitCancellation
import org.junit.Rule
import org.junit.Test

class ScreenCapabilityPickerTest {
    @get:Rule
    val compose = createComposeRule()
    @get:Rule val testName = org.junit.rules.TestName()
    private val cores = mutableListOf<CoreRuntime>()
    private var previousIme: String? = null
    private var fixtureImeWasEnabled = false
    private val fixtureIme get() = "${InstrumentationRegistry.getInstrumentation().context.packageName}/com.dbpprt.dieter.screens.DockedTestIme"

    @org.junit.Before fun showFullSoftKeyboard() {
        if (testName.methodName != "machineRefreshAndKeyboardKeepTheSameSessionAndViewport") return
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val resolver = instrumentation.targetContext.contentResolver
        previousIme = android.provider.Settings.Secure.getString(resolver, "default_input_method")
        fixtureImeWasEnabled = instrumentation.targetContext.getSystemService(android.view.inputmethod.InputMethodManager::class.java)
            .enabledInputMethodList.any { it.id == fixtureIme }
        shell("ime enable $fixtureIme")
        shell("ime set $fixtureIme")
    }

    private fun shell(command: String) {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
        android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
    }

    @org.junit.After fun restoreSoftKeyboardPreference() {
        if (previousIme == null) return
        previousIme?.let { shell("ime set $it") }
        if (!fixtureImeWasEnabled) shell("ime disable $fixtureIme")
    }

    /** A screen host over an isolated core whose routes never connect. */
    private fun host(attempts: java.util.concurrent.atomic.AtomicInteger? = null): ScreenHost {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val core = SharedCore.create(context, null, File(context.noBackupFilesDir, "screen-picker-${UUID.randomUUID()}")).also { cores += it }
        return ScreenHost(context, core) { { attempts?.incrementAndGet(); awaitCancellation() } }
    }

    @org.junit.After fun shutdown() = runBlocking { cores.forEach { it.shutdown() } }

    @Test fun canvasControlsAndTouchEventsKeepZoomAnchoredAndFitRecoverable() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val host = host()
        lateinit var canvas: ScreenCanvasView
        var generation by mutableIntStateOf(0)
        compose.setContent {
            var zoom by remember { mutableDoubleStateOf(1.0) }
            var fitted by remember { mutableStateOf(true) }
            DisposableEffect(Unit) { onDispose { canvas.release(); host.close() } }
            DieterTheme {
                Box(Modifier.fillMaxSize()) {
                    key(generation) { AndroidView(factory = { ScreenCanvasView(it, host).also { view ->
                        canvas = view
                        view.onCanvasChanged = { zoom = view.canvasModel.zoom; fitted = view.canvasModel.isFitted }
                    } }, onRelease = { it.release() }, modifier = Modifier.fillMaxSize()) }
                    ScreenCanvasControls(zoom, fitted, { canvas.zoomCanvas(it) }, { canvas.resetCanvas(animated = true) },
                        Modifier.align(Alignment.BottomCenter).padding(12.dp))
                }
            }
        }
        compose.onNodeWithTag("screen-zoom-in").performClick()
        compose.waitUntil { canvas.canvasModel.zoom == 1.25 }
        compose.onNodeWithText("125%").assertIsDisplayed()
        val previousCanvas = canvas
        compose.runOnIdle { generation++ }
        compose.waitForIdle()
        compose.runOnIdle {
            assertNotSame(previousCanvas, canvas)
            assertEquals(1.25, canvas.canvasModel.zoom, .0001)
            val matrix = (canvas.getChildAt(0) as android.view.TextureView).getTransform(null)
            val bounds = android.graphics.RectF(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat())
            matrix.mapRect(bounds)
            assertEquals(canvas.canvasModel.remoteWidth * canvas.canvasModel.scale, bounds.width().toDouble(), .01)
        }
        compose.onNodeWithTag("screen-zoom-out").performClick()
        compose.waitUntil { canvas.canvasModel.isFitted }
        compose.onNodeWithText("Fit · 100%").assertIsDisplayed()
        // Rapid presses accumulate complete steps while the visual transition runs.
        compose.runOnIdle { canvas.zoomCanvas(1.25); canvas.zoomCanvas(1.25) }
        compose.waitUntil { canvas.canvasModel.zoom == 1.5625 }
        compose.runOnIdle { canvas.resetCanvas() }
        compose.runOnIdle {
            val m = canvas.canvasModel
            val cx = canvas.width * .5f; val cy = canvas.height * .5f
            val time = SystemClock.uptimeMillis()
            fun dispatch(action: Int, points: List<Pair<Float, Float>>, offset: Long) {
                val props = Array(points.size) { i -> MotionEvent.PointerProperties().apply { id = i; toolType = MotionEvent.TOOL_TYPE_FINGER } }
                val coords = Array(points.size) { i -> MotionEvent.PointerCoords().apply { x = points[i].first; y = points[i].second; pressure = 1f } }
                val event = MotionEvent.obtain(time, time + offset, action, points.size, props, coords,
                    0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
                try { assertTrue(canvas.dispatchTouchEvent(event)) } finally { event.recycle() }
            }
            dispatch(MotionEvent.ACTION_DOWN, listOf(cx - 100 to cy), 0)
            dispatch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                listOf(cx - 100 to cy, cx + 100 to cy), 20)
            dispatch(MotionEvent.ACTION_MOVE, listOf(cx - 180 to cy + 40, cx + 220 to cy + 40), 40)
            assertEquals(2.0, m.zoom, .001)
            assertEquals(cx + 20.0, m.left + m.remoteWidth * m.scale / 2, .1)
            assertEquals(cy + 40.0, m.top + m.remoteHeight * m.scale / 2, .1)
            dispatch(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                listOf(cx - 180 to cy + 40, cx + 220 to cy + 40), 60)
            dispatch(MotionEvent.ACTION_UP, listOf(cx - 180 to cy + 40), 80)
            assertEquals(Point(.5, .5), m.cursor)
        }
        compose.onNodeWithText("200%").assertIsDisplayed()
        compose.runOnIdle {
            // Ending a session restores the fitted view, as the Screens page does.
            canvas.resetSession()
            assertTrue(canvas.canvasModel.isFitted)
            val matrix = (canvas.getChildAt(0) as android.view.TextureView).getTransform(null)
            val displayed = android.graphics.RectF(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat())
            matrix.mapRect(displayed)
            assertEquals(canvas.canvasModel.left, displayed.left.toDouble(), .01)
            assertEquals(canvas.canvasModel.top, displayed.top.toDouble(), .01)
            assertEquals(canvas.canvasModel.remoteWidth * canvas.canvasModel.scale, displayed.width().toDouble(), .01)
            // Also exercise Fit independently from the session-reset path.
            canvas.canvasModel.transform(2.0, Point(200.0, 300.0), Point(220.0, 350.0))
            canvas.zoomCanvas(1.0)
        }
        compose.onNodeWithTag("screen-fit").performClick()
        compose.waitUntil { canvas.canvasModel.isFitted }
        val capture = com.dbpprt.dieter.screens.captureScreenFixture()
        try {
            java.io.File(context.getExternalFilesDir(null), "screen-canvas-controls.png").outputStream().use {
                capture.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
        } finally { capture.recycle() }
        compose.onNodeWithText("Fit · 100%").assertIsDisplayed()
        repeat(7) {
            val expected = (canvas.canvasModel.zoom / 1.25).coerceAtLeast(.25)
            compose.onNodeWithTag("screen-zoom-out").performClick()
            compose.waitUntil { kotlin.math.abs(canvas.canvasModel.zoom - expected) < .00001 }
        }
        compose.onNodeWithTag("screen-zoom-out").assertIsNotEnabled()
        compose.onNodeWithText("25%").assertIsDisplayed()
        compose.onNodeWithTag("screen-fit").performClick()
        compose.waitUntil { canvas.canvasModel.isFitted }
    }


    @Test
    fun unreadyHostCanBeSelectedForGuidanceAndRetryWhileOfflineHostsStayDisabled() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val machines = listOf(
            MachineRow(
                id = "linux",
                label = "Linux host",
                address = "isolated",
                daemonId = "daemon-linux",
                remoteDesktopReady = false,
                remoteDesktopReason = "No supported graphical login session is active",
                remoteDesktopPlatform = "linux",
            ),
            MachineRow(
                id = "mac",
                label = "Mac host",
                address = "isolated",
                daemonId = "daemon-mac",
                remoteDesktopReady = true,
                remoteDesktopPlatform = "darwin",
            ),
            MachineRow(id = "offline", label = "Offline host", address = "isolated", online = false),
        )
        val host = host()
        compose.setContent {
            DieterTheme {
                ScreenWorkspace(machines = machines, padding = PaddingValues(), host = host)
            }
        }

        compose.onNodeWithTag("screen-machine-offline").assertIsNotEnabled()
        compose.onNodeWithTag("screen-machine-linux").assertIsEnabled().performClick()
        compose.onNodeWithText("No supported graphical login session is active").assertIsDisplayed()
        compose.onNodeWithTag("screen-connect").assertIsEnabled()
        compose.onNodeWithTag("screen-disconnect").performClick()
        compose.onNodeWithTag("screen-machine-mac").assertIsEnabled().performClick()
        compose.onNodeWithTag("screen-canvas").assertIsDisplayed()
        compose.onNodeWithTag("screen-machines").assertDoesNotExist()
    }
    @Test fun machineRefreshAndKeyboardKeepTheSameSessionAndViewport() {
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        val host = host(attempts)
        val initial = listOf(
            MachineRow("z", "Studio Mac", "isolated", daemonId = "z", remoteDesktopPlatform = "darwin", releaseVersion = "0.4.339"),
            MachineRow("a", "Build Linux", "isolated", daemonId = "a", remoteDesktopPlatform = "linux"),
        )
        var machines by mutableStateOf(initial)
        compose.setContent { DieterTheme { androidx.compose.material3.Scaffold { padding -> ScreenWorkspace(machines, padding, host) } } }
        fun top(id: String) = compose.onNodeWithTag(id).fetchSemanticsNode().boundsInRoot.top
        assertTrue(top("screen-machine-a") < top("screen-machine-z"))
        compose.runOnIdle { machines = initial.reversed().map { it.copy(latencyMs = 42, online = it.id != "a") } }
        assertTrue(top("screen-machine-a") < top("screen-machine-z"))
        capture("screen-machines.png")
        compose.onNodeWithTag("screen-machine-z").performClick()
        val canvas = compose.runOnIdle { findCanvas() }
        compose.runOnIdle {
            var context = canvas.context
            while (context is android.content.ContextWrapper && context !is android.app.Activity) context = context.baseContext
            WindowCompat.setDecorFitsSystemWindows((context as android.app.Activity).window, false)
        }
        compose.waitForIdle()
        compose.runOnIdle { canvas.zoomCanvas(2.0) }
        compose.waitUntil { canvas.canvasModel.zoom == 2.0 }
        val before = compose.runOnIdle { listOf(canvas.width.toDouble(), canvas.height.toDouble(), canvas.canvasModel.scale, canvas.canvasModel.panX, canvas.canvasModel.panY) }
        compose.runOnIdle { machines = emptyList() }
        compose.onNodeWithText("Studio Mac").assertIsDisplayed()
        assertEquals(1, attempts.get())
        compose.runOnIdle { assertSame(canvas, findCanvas()); assertEquals(2.0, canvas.canvasModel.zoom, 0.0) }
        val accessoryBottom = compose.onNodeWithTag("screen-keyboard").fetchSemanticsNode().boundsInRoot.bottom
        compose.runOnIdle {
            canvas.showKeyboard(true)
        }
        try {
            compose.waitUntil(20_000) { ViewCompat.getRootWindowInsets(canvas)?.getInsets(WindowInsetsCompat.Type.ime())?.bottom?.let { it > 100 } == true }
        } catch (failure: Throwable) {
            capture("screen-keyboard-failure.png")
            throw AssertionError("Docked test IME did not appear: ${ViewCompat.getRootWindowInsets(canvas)?.getInsets(WindowInsetsCompat.Type.ime())}", failure)
        }
        // Insets are published before the IME's animated window reaches its
        // final position. Require settled visibility and the raised accessory.
        SystemClock.sleep(450)
        compose.waitForIdle()
        compose.runOnIdle {
            assertTrue(ViewCompat.getRootWindowInsets(canvas)?.isVisible(WindowInsetsCompat.Type.ime()) == true)
            assertEquals(before, listOf(canvas.width.toDouble(), canvas.height.toDouble(), canvas.canvasModel.scale, canvas.canvasModel.panX, canvas.canvasModel.panY))
        }
        capture("screen-keyboard.png")
        compose.onNodeWithContentDescription("Hide keyboard").assertIsDisplayed()
        assertTrue(compose.onNodeWithTag("screen-keyboard").fetchSemanticsNode().boundsInRoot.bottom < accessoryBottom - 100)
        compose.runOnIdle { canvas.showKeyboard(false) }
        compose.waitUntil(10_000) { ViewCompat.getRootWindowInsets(canvas)?.isVisible(WindowInsetsCompat.Type.ime()) == false }
        compose.runOnIdle {
            assertEquals(before, listOf(canvas.width.toDouble(), canvas.height.toDouble(), canvas.canvasModel.scale, canvas.canvasModel.panX, canvas.canvasModel.panY))
        }
        compose.onNodeWithContentDescription("Connection details").performClick()
        compose.onNodeWithText("Signaling · Negotiating").assertIsDisplayed()
        compose.onNodeWithText("Done").performClick()
        compose.runOnIdle { assertSame(canvas, findCanvas()) }
        compose.onNodeWithTag("screen-disconnect").performClick()
        compose.onNodeWithTag("screen-machines").assertIsDisplayed()
    }

    @Test fun terminalMachineMenuDoesNotMoveAfterSelectionOrPresenceUpdates() {
        val initial = listOf(MachineRow("b", "Studio", "", daemonId = "b"), MachineRow("a", "Build", "", daemonId = "a"),
            MachineRow("c", "Studio", "", daemonId = "c"))
        var machines by mutableStateOf(initial)
        var selected by mutableStateOf<String?>("a")
        compose.setContent { DieterTheme { Box(Modifier.fillMaxSize().padding(top = 32.dp)) {
            TerminalMachinePicker(machines, selected) { selected = it }
        } } }
        compose.onNodeWithTag("terminal-machine").performClick()
        fun positions() = listOf("a", "b", "c").map { compose.onNodeWithTag("terminal-machine-$it").fetchSemanticsNode().boundsInRoot.top }
        val first = positions()
        assertTrue(first.zipWithNext().all { (a, b) -> a < b })
        compose.runOnIdle { machines = initial.reversed().map { it.copy(latencyMs = 13, online = it.id != "a") } }
        assertEquals(first, positions())
        compose.onNodeWithTag("terminal-machine-a").assertIsNotEnabled()
        compose.onNodeWithTag("terminal-machine-b").performClick()
        compose.runOnIdle { assertEquals("b", selected) }
        compose.onNodeWithTag("terminal-machine").performClick()
        assertEquals(first, positions())
        capture("terminal-machine-picker.png")
    }

    private fun findCanvas(): ScreenCanvasView {
        fun find(view: View): ScreenCanvasView? {
            if (view is ScreenCanvasView) return view
            if (view is ViewGroup) for (i in 0 until view.childCount) find(view.getChildAt(i))?.let { return it }
            return null
        }
        return requireNotNull(WindowInspector.getGlobalWindowViews().firstNotNullOfOrNull(::find))
    }

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File)
            ?: requireNotNull(instrumentation.targetContext.getExternalFilesDir(null))
        output.mkdirs()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        try { File(output, name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } }
        finally { bitmap.recycle() }
    }

}
