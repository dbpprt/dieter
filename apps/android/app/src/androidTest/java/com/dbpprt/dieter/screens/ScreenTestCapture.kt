package com.dbpprt.dieter.screens

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Capture only the owned fixture window; no competing UiAutomation service. */
internal fun captureScreenFixture(): Bitmap {
    var latch = CountDownLatch(1)
    var image: Bitmap? = null
    var result = PixelCopy.ERROR_UNKNOWN
    data class Layer(val bitmap: Bitmap, val x: Float, val y: Float, var result: Int = PixelCopy.ERROR_UNKNOWN)
    val layers = mutableListOf<Layer>()
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).single()
        val view = activity.window.decorView
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        image = bitmap
        fun surfaces(view: View): List<SurfaceView> = when (view) {
            is SurfaceView -> if (view.isShown && view.holder.surface.isValid &&
                (view.parent as? ScreenCanvasView)?.isVisibleVideoSurface(view) != false) listOf(view) else emptyList()
            is ViewGroup -> (0 until view.childCount).flatMap { surfaces(view.getChildAt(it)) }
            else -> emptyList()
        }
        val surfaces = surfaces(view)
        latch = CountDownLatch(surfaces.size + 1)
        surfaces.forEach { surface ->
            val location = IntArray(2); surface.getLocationInWindow(location)
            val layer = Layer(Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888), location[0].toFloat(), location[1].toFloat())
            layers.add(layer)
            PixelCopy.request(surface, layer.bitmap, { layer.result = it; latch.countDown() }, Handler(Looper.getMainLooper()))
        }
        PixelCopy.request(activity.window, bitmap, { result = it; latch.countDown() }, Handler(Looper.getMainLooper()))
    }
    check(latch.await(5, TimeUnit.SECONDS) && result == PixelCopy.SUCCESS) { "Fixture window capture failed: $result" }
    val window = requireNotNull(image)
    if (layers.isEmpty()) return window
    check(layers.all { it.result == PixelCopy.SUCCESS }) { "Fixture video surface capture failed: ${layers.map { it.result }}" }
    // A window capture contains a transparent SurfaceView hole. Capture the
    // owned video layers too, then overlay window UI/cursor. This is fixture
    // layer evidence, not an optical timing or system-wide screenshot.
    return Bitmap.createBitmap(window.width, window.height, Bitmap.Config.ARGB_8888).also { combined ->
        Canvas(combined).apply {
            layers.forEach { drawBitmap(it.bitmap, it.x, it.y, null); it.bitmap.recycle() }
            drawBitmap(window, 0f, 0f, null)
        }
        window.recycle()
    }
}
