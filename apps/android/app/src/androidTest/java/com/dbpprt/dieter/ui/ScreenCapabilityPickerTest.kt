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
import org.junit.Assert.*
import com.dbpprt.dieter.ui.theme.DieterTheme
import kotlinx.coroutines.awaitCancellation
import org.junit.Rule
import org.junit.Test

class ScreenCapabilityPickerTest {
    @get:Rule
    val compose = createComposeRule()
    private val cores = mutableListOf<CoreRuntime>()

    /** A screen host over an isolated core whose routes never connect. */
    private fun host(): ScreenHost {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val core = SharedCore.create(context, null, File(context.noBackupFilesDir, "screen-picker-${UUID.randomUUID()}")).also { cores += it }
        return ScreenHost(context, core) { { awaitCancellation() } }
    }

    @org.junit.After fun shutdown() = runBlocking { cores.forEach { it.shutdown() } }

    @Test fun canvasControlsAndTouchEventsKeepZoomAnchoredAndFitRecoverable() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val host = host()
        lateinit var canvas: ScreenCanvasView
        compose.setContent {
            var zoom by remember { mutableDoubleStateOf(1.0) }
            var fitted by remember { mutableStateOf(true) }
            DisposableEffect(Unit) { onDispose { canvas.release(); host.close() } }
            DieterTheme {
                Box(Modifier.fillMaxSize()) {
                    AndroidView(factory = { ScreenCanvasView(it, host).also { view ->
                        canvas = view
                        view.onCanvasChanged = { zoom = view.canvasModel.zoom; fitted = view.canvasModel.isFitted }
                    } }, modifier = Modifier.fillMaxSize())
                    ScreenCanvasControls(zoom, fitted, { canvas.zoomCanvas(it) }, { canvas.resetCanvas(animated = true) },
                        Modifier.align(Alignment.BottomCenter).padding(12.dp))
                }
            }
        }
        compose.onNodeWithTag("screen-zoom-in").performClick()
        compose.waitUntil { canvas.canvasModel.zoom == 1.25 }
        compose.onNodeWithText("125%").assertIsDisplayed()
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

        compose.onNodeWithTag("screen-machine").performClick()
        compose.onNodeWithTag("screen-machine-offline").assertIsNotEnabled()
        compose.onNodeWithTag("screen-machine-linux").assertIsEnabled().performClick()
        compose.onNodeWithText("No supported graphical login session is active").assertIsDisplayed()
        compose.onNodeWithTag("screen-connect").assertIsEnabled()
        compose.onNodeWithTag("screen-machine").performClick()
        compose.onNodeWithTag("screen-machine-mac").assertIsEnabled().performClick()
        compose.onNodeWithTag("screen-connect").assertIsEnabled()
    }
}
