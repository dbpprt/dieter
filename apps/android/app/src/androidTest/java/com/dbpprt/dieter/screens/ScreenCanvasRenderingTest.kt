package com.dbpprt.dieter.screens

import android.graphics.Color
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.TextureView
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.viewinterop.AndroidView
import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.core.screens.*
import com.dbpprt.dieter.e2e.Evidence
import com.dbpprt.dieter.e2e.TestCore
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import kotlin.math.abs

/** Real EGL pixels and Android composition, including a desktop that sends no new frame during zoom. */
class ScreenCanvasRenderingTest {
    @get:Rule val compose = createComposeRule()
    private lateinit var canvas: ScreenCanvasView

    @Test fun staticVideoPixelsFollowZoomPanAndFitWithoutStaleRegions() {
        val core = TestCore()
        val host = ScreenHost(core.context, core.core)
        val engine = host.media.create(ScreenMediaConfig(RTCConfiguration(), listOf(RtpCodec("H264")), false, emptyList()),
            object : ScreenMediaEvents {
                override fun localCandidate(candidate: RemoteDesktopICECandidate) = Unit
                override fun peerState(state: PeerState) = Unit
                override fun channelState(label: String, open: Boolean) = Unit
                override fun channelMessage(label: String, bytes: ByteArray) = Unit
                override fun decoded(rtpTimestamp: UInt) = Unit
                override fun presented(rtpTimestamp: UInt) = Unit
                override fun mediaPath(relayed: Boolean) = Unit
                override fun hevcUnavailable(reason: String) = Unit
                override fun failure(message: String) = Unit
            }) as AndroidScreenMedia.Engine
        try {
            compose.setContent { AndroidView(factory = { ScreenCanvasView(it, host).also { canvas = it } }, modifier = Modifier.fillMaxSize()) }
            compose.waitUntil(10_000) { (canvas.getChildAt(0) as TextureView).isAvailable }
            val buffer = JavaI420Buffer.allocate(640, 360)
            for (y in 0 until 360) for (x in 0 until 640)
                buffer.dataY.put(y * buffer.strideY + x, luma(x < 320, y < 180).toByte())
            for (y in 0 until 180) for (x in 0 until 320) {
                buffer.dataU.put(y * buffer.strideU + x, 128.toByte())
                buffer.dataV.put(y * buffer.strideV + x, 128.toByte())
            }
            val frame = VideoFrame(buffer, 0, System.nanoTime())
            try { requireNotNull(host.media.videoSink)(frame, engine.token) } finally { frame.release() }
            compose.waitUntil(10_000) { canvas.canvasModel.remoteWidth == 640.0 }
            assertPixels(canvas, "fit")
            // No new video is delivered throughout these operations.
            for ((index, factor) in listOf(.5, 4.0, .25, 4.0, .5).withIndex()) {
                val expected = canvas.canvasModel.zoom * factor
                compose.runOnIdle { canvas.zoomCanvas(factor) }
                compose.waitUntil { abs(canvas.canvasModel.zoom - expected) < .0001 }
                assertPixels(canvas, "zoom-$index")
            }
            pinch(1.6f, canvas.width * .15f, canvas.height * .08f)
            assertPixels(canvas, "pinch-in-and-pan")
            pinch(.5f, -canvas.width * .1f, -canvas.height * .08f)
            assertPixels(canvas, "pinch-out-and-pan")
            compose.runOnIdle { canvas.resetCanvas(animated = true) }
            compose.waitUntil { canvas.canvasModel.isFitted }
            assertPixels(canvas, "reset-fit")
        } finally {
            if (::canvas.isInitialized) compose.runOnIdle { canvas.release() }
            engine.close()
            host.close()
            core.close()
            core.delete()
        }
    }

    private fun luma(left: Boolean, top: Boolean) = if (top) { if (left) 40 else 100 } else { if (left) 160 else 220 }

    private fun pinch(factor: Float, dx: Float, dy: Float) = compose.runOnIdle {
        val cx = canvas.width / 2f; val cy = canvas.height / 2f
        val down = SystemClock.uptimeMillis()
        fun dispatch(action: Int, points: List<Pair<Float, Float>>, offset: Long) {
            val properties = Array(points.size) { i -> MotionEvent.PointerProperties().apply { id = i; toolType = MotionEvent.TOOL_TYPE_FINGER } }
            val coordinates = Array(points.size) { i -> MotionEvent.PointerCoords().apply { x = points[i].first; y = points[i].second; pressure = 1f } }
            val event = MotionEvent.obtain(down, down + offset, action, points.size, properties, coordinates,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { assertTrue(canvas.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
        val start = listOf(cx - 100 to cy, cx + 100 to cy)
        val end = listOf(cx - 100 * factor + dx to cy + dy, cx + 100 * factor + dx to cy + dy)
        val zoom = canvas.canvasModel.zoom
        dispatch(MotionEvent.ACTION_DOWN, start.take(1), 0)
        dispatch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), start, 20)
        dispatch(MotionEvent.ACTION_MOVE, end, 40)
        dispatch(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), end, 60)
        dispatch(MotionEvent.ACTION_UP, end.take(1), 80)
        assertEquals(zoom * factor, canvas.canvasModel.zoom, .0001)
    }

    private fun assertPixels(canvas: ScreenCanvasView, name: String) {
        compose.waitForIdle()
        SystemClock.sleep(100) // Allow the compositor to latch the final animation transaction.
        val location = IntArray(2)
        compose.runOnIdle { canvas.getLocationInWindow(location) }
        val image = captureScreenFixture()
        fun capture() = Evidence.save(image, "canvas-$name.png")
        try {
            val m = canvas.canvasModel
            for (row in 1..11) for (column in 1..9) {
                val x = canvas.width * column / 10
                val y = canvas.height * row / 12
                val rx = (x - m.left) / m.scale
                val ry = (y - m.top) / m.scale
                // Avoid filtering at the frame's border or at a quadrant seam.
                if (listOf(abs(rx), abs(rx - 320), abs(rx - 640), abs(ry), abs(ry - 180), abs(ry - 360)).any { it < 5 }) continue
                val expected = if (m.contains(x.toDouble(), y.toDouble())) {
                    val gray = ((luma(rx < 320, ry < 180) - 16) * 1.164).toInt()
                    Color.rgb(gray, gray, gray)
                } else Color.rgb(12, 15, 20)
                val actual = image.getPixel(location[0] + x, location[1] + y)
                assertTrue("$name at $x,$y: expected ${Integer.toHexString(expected)}, got ${Integer.toHexString(actual)}",
                    abs(Color.red(expected) - Color.red(actual)) < 12 &&
                        abs(Color.green(expected) - Color.green(actual)) < 12 && abs(Color.blue(expected) - Color.blue(actual)) < 12)
            }
            if (name in setOf("zoom-0", "pinch-in-and-pan", "reset-fit")) capture()
        } catch (failure: Throwable) {
            capture()
            throw failure
        } finally { image.recycle() }
    }
}
