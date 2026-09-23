package com.dbpprt.dieter.ui

import android.Manifest
import android.graphics.Rect
import android.view.MotionEvent
import android.view.InputDevice
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.rules.ActivityScenarioRule
import android.os.Looper
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import android.os.Trace
import android.util.Log
import android.view.FrameMetrics
import android.view.Window
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import androidx.core.app.FrameMetricsAggregator
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.BuildConfig
import org.junit.Assume.assumeFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/** Visible navigation smoke that catches multi-frame main-thread stalls such as synchronous fsync. */
@RunWith(AndroidJUnit4::class)
class MainActivityFramePerformanceTest {
    private val permissionRule = GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)
    private val activityRule = ActivityScenarioRule(MainActivity::class.java)
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private lateinit var activity: MainActivity
    private var measuring = false

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(activityRule)

    @Test
    fun repeatedPrimaryNavigationHasNoSevereMainThreadStall() {
        assumeFalse("Frame budgets require the production-mode app: just android performance-test", BuildConfig.DEBUG)
        val controlOnly = InstrumentationRegistry.getArguments().getString("dieterPerformanceControl") == "true"
        activityRule.scenario.onActivity {
            activity = it
            if (controlOnly) installNativeControl()
        }
        Log.i("DieterPerformance", "measurementMode=${if (controlOnly) "native-control" else "dieter-navigation"}")
        instrumentation.waitForIdleSync()
        // A disconnected saved gateway opens the connection sheet on launch.
        // Native input must dismiss that visible scrim before measuring routes.
        val startup = awaitNode { findClickable(it, "Close sheet") ?: findClickable(it, "Chats") }
        if (startup.contentDescription?.toString() == "Close sheet") {
            clickVisibleLabel("Close sheet")
            SystemClock.sleep(700)
        }
        // Use the real Choreographer clock and native input. Compose's test
        // clock drives entire animations synchronously inside waitForIdle,
        // producing artificial FrameMetrics UNKNOWN_DELAY stalls.
        // Warm each route once before recording the same repeated journey.
        listOf("nav-chats", "nav-board", "nav-terminals", "nav-board").forEach { tag ->
            navigate(tag)
        }
        val aggregator = FrameMetricsAggregator(FrameMetricsAggregator.TOTAL_DURATION)
        measuring = true
        aggregator.add(activity)
        val sampleMain = InstrumentationRegistry.getArguments().getString("dieterPerformanceSample") == "true"
        val traceFrames = InstrumentationRegistry.getArguments().getString("dieterPerformanceFrames") == "true"
        val framePhases = mutableListOf<LongArray>()
        var droppedPhaseFrames = 0
        var truncatedPhaseFrames = 0
        val phaseThread = if (traceFrames) HandlerThread("frame-phase-diagnostics").apply { start() } else null
        val phaseMetrics = linkedMapOf(
            "total" to FrameMetrics.TOTAL_DURATION,
            "input" to FrameMetrics.INPUT_HANDLING_DURATION,
            "animation" to FrameMetrics.ANIMATION_DURATION,
            "layout" to FrameMetrics.LAYOUT_MEASURE_DURATION,
            "draw" to FrameMetrics.DRAW_DURATION,
            "sync" to FrameMetrics.SYNC_DURATION,
            "command" to FrameMetrics.COMMAND_ISSUE_DURATION,
            "swap" to FrameMetrics.SWAP_BUFFERS_DURATION,
            "delay" to FrameMetrics.UNKNOWN_DELAY_DURATION,
            "gpu" to FrameMetrics.GPU_DURATION,
        )
        val phaseListener = Window.OnFrameMetricsAvailableListener { _, frame, dropped ->
            // The framework reuses FrameMetrics. Copy bounded primitive values
            // on the callback thread; never inspect stacks or log on Main.
            val values = phaseMetrics.values.map(frame::getMetric).toLongArray()
            synchronized(framePhases) {
                droppedPhaseFrames += dropped
                if (framePhases.size < 4096) framePhases += values else truncatedPhaseFrames++
            }
        }
        if (phaseThread != null) activity.window.addOnFrameMetricsAvailableListener(phaseListener, Handler(phaseThread.looper))
        val sampling = AtomicBoolean(sampleMain)
        val samples = mutableMapOf<String, Int>()
        val sampler = if (sampleMain) thread(name = "performance-main-sampler") {
            while (sampling.get()) {
                val stack = Looper.getMainLooper().thread.stackTrace.take(24).joinToString("\n")
                samples[stack] = (samples[stack] ?: 0) + 1
                Thread.sleep(20)
            }
        } else null
        val slowFrames = Window.OnFrameMetricsAvailableListener { _, frame, _ ->
            if (frame.getMetric(FrameMetrics.TOTAL_DURATION) >= 120_000_000) {
                fun ms(metric: Int) = frame.getMetric(metric) / 1_000_000
                Log.i("DieterPerformance", "slowFrame total=${ms(FrameMetrics.TOTAL_DURATION)} " +
                    "input=${ms(FrameMetrics.INPUT_HANDLING_DURATION)} animation=${ms(FrameMetrics.ANIMATION_DURATION)} " +
                    "layout=${ms(FrameMetrics.LAYOUT_MEASURE_DURATION)} draw=${ms(FrameMetrics.DRAW_DURATION)} " +
                    "sync=${ms(FrameMetrics.SYNC_DURATION)} command=${ms(FrameMetrics.COMMAND_ISSUE_DURATION)} " +
                    "swap=${ms(FrameMetrics.SWAP_BUFFERS_DURATION)} delay=${ms(FrameMetrics.UNKNOWN_DELAY_DURATION)} " +
                    "gpu=${if (android.os.Build.VERSION.SDK_INT >= 31) ms(FrameMetrics.GPU_DURATION) else -1}")
            }
        }
        if (sampleMain) activity.window.addOnFrameMetricsAvailableListener(slowFrames, Handler(Looper.getMainLooper()))
        val cpuStarted = Process.getElapsedCpuTime()
        val wallStarted = SystemClock.elapsedRealtime()
        var navigationCpuMs: Long
        var navigationWallMs: Long
        var metrics: Array<android.util.SparseIntArray?>?

        try {
            repeat(4) {
                navigate("nav-chats")
                navigate("nav-board")
                navigate("nav-terminals")
            }
        } finally {
            navigationCpuMs = Process.getElapsedCpuTime() - cpuStarted
            navigationWallMs = SystemClock.elapsedRealtime() - wallStarted
            metrics = aggregator.remove(activity)
            if (phaseThread != null) {
                activity.window.removeOnFrameMetricsAvailableListener(phaseListener)
                phaseThread.quitSafely()
                phaseThread.join(2_000)
            }
            sampling.set(false)
            sampler?.join(2_000)
            if (sampleMain) {
                activity.window.removeOnFrameMetricsAvailableListener(slowFrames)
                samples.entries.sortedByDescending { it.value }.take(20).forEach { (stack, count) ->
                    Log.i("DieterPerformance", "mainSamples count=$count\n$stack")
                }
            }
        }

        if (phaseThread != null) {
            val captured = synchronized(framePhases) { framePhases.toList() }
            Log.i("DieterPerformance", "frameDiagnostics captured=${captured.size} dropped=$droppedPhaseFrames truncated=$truncatedPhaseFrames")
            phaseMetrics.keys.forEachIndexed { index, name ->
                val values = captured.map { it[index] / 1_000_000.0 }.filter { it >= 0 }.sorted()
                if (values.isNotEmpty()) Log.i("DieterPerformance", "phase=$name frames=${values.size} " +
                    "p50Ms=${values[values.size / 2]} p95Ms=${values[(values.size * 0.95).toInt().coerceAtMost(values.lastIndex)]} maxMs=${values.last()}")
            }
            captured.sortedByDescending { it[0] }.take(20).forEach { frame ->
                Log.i("DieterPerformance", "framePhases " + phaseMetrics.keys.mapIndexed { index, name ->
                    "$name=${frame[index] / 1_000_000.0}"
                }.joinToString(" "))
            }
        }
        val histogram = requireNotNull(requireNotNull(metrics)[FrameMetricsAggregator.TOTAL_INDEX])
        var totalFrames = 0
        var severeFrames = 0
        val orderedDurations = mutableListOf<Int>()
        for (index in 0 until histogram.size()) {
            val durationMs = histogram.keyAt(index)
            val count = histogram.valueAt(index)
            totalFrames += count
            if (durationMs >= SEVERE_FRAME_MS) severeFrames += count
            repeat(count) { orderedDurations += durationMs }
        }

        assertTrue("FrameMetrics recorded no frames", totalFrames > 0)
        val sorted = orderedDurations.sorted()
        fun percentile(fraction: Double) = sorted[(sorted.size * fraction).toInt().coerceAtMost(sorted.lastIndex)]
        val p95 = percentile(0.95)
        Log.i(
            "DieterPerformance",
            "navigation frames=$totalFrames p50Ms=${percentile(0.50)} p95Ms=$p95 p99Ms=${percentile(0.99)} maxMs=${sorted.last()} " +
                "over16Ms=${sorted.count { it > 16 }} over33Ms=${sorted.count { it > 33 }} " +
                "cpuMs=$navigationCpuMs wallMs=$navigationWallMs",
        )
        // Separate passive-window CPU from navigation. These are process
        // counters (including the test runner), not a physical battery estimate.
        instrumentation.waitForIdleSync()
        val idleCpuStarted = Process.getElapsedCpuTime()
        val idleWallStarted = SystemClock.elapsedRealtime()
        SystemClock.sleep(5_000)
        Log.i(
            "DieterPerformance",
            "idle cpuMs=${Process.getElapsedCpuTime() - idleCpuStarted} " +
                "wallMs=${SystemClock.elapsedRealtime() - idleWallStarted}",
        )
        // Retain idle evidence even when navigation fails its unchanged budget.
        // Total frame duration also includes renderer/buffer waits; a failure
        // alone does not attribute the delay to main-thread application CPU.
        assertEquals("Detected a >=${SEVERE_FRAME_MS}ms frame", 0, severeFrames)
        assertTrue("Navigation p95 was ${p95}ms", p95 < P95_FRAME_MS)
    }

    // Optional diagnostic control: the same window, renderer and input driver
    // with ordinary Android buttons. Never count this as Dieter qualification;
    // it isolates emulator/compositor cost from the Compose application tree.
    private fun installNativeControl() {
        val root = android.widget.LinearLayout(activity).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = android.view.Gravity.BOTTOM
        }
        val controls = mutableMapOf<String, android.widget.Button>()
        lateinit var terminal: android.widget.Button
        fun select(label: String) {
            controls.forEach { (name, button) -> button.isSelected = name == label }
            terminal.visibility = android.view.View.GONE
        }
        terminal = android.widget.Button(activity).apply {
            text = "Terminal"
            isAllCaps = false
            visibility = android.view.View.GONE
            setOnClickListener { select("Tools") }
        }
        root.addView(terminal)
        val bar = android.widget.LinearLayout(activity)
        for (label in listOf("Inbox", "Projects", "Chats", "Tools")) {
            val button = android.widget.Button(activity).apply {
                text = label
                isAllCaps = false
                setOnClickListener {
                    if (label == "Tools") terminal.visibility = android.view.View.VISIBLE
                    else select(label)
                }
            }
            controls[label] = button
            bar.addView(button, android.widget.LinearLayout.LayoutParams(0, 160, 1f))
        }
        root.addView(bar)
        select("Projects")
        activity.setContentView(root)
    }

    private fun navigate(tag: String) {
        Trace.beginSection("DieterNavigation:${if (measuring) "measured" else "warmup"}:$tag")
        try {
            navigateVisibleRoute(tag)
        } finally {
            Trace.endSection()
        }
    }

    private fun navigateVisibleRoute(tag: String) {
        val label = when (tag) {
            "nav-chats" -> "Chats"
            "nav-board" -> "Projects"
            "nav-terminals" -> "Terminal"
            else -> error("Unknown route $tag")
        }
        if (tag == "nav-terminals") {
            clickVisibleLabel("Tools")
            SystemClock.sleep(700)
        }
        clickVisibleLabel(label)
        val selected = if (tag == "nav-terminals") "Tools" else label
        awaitNode("$selected selected after $label") { root -> findClickable(root, selected)?.takeIf { it.isSelected } }
        // Let the actual display clock finish the pager/sheet transition.
        // This sleep is on the instrumentation thread, never Main.
        SystemClock.sleep(700)
        instrumentation.waitForIdleSync()
    }

    private fun clickVisibleLabel(label: String) {
        val node = awaitNode("$label tap target") { findClickable(it, label) }
        tap(node, label)
    }

    private fun tap(node: AccessibilityNodeInfo, label: String) {
        val bounds = Rect().also(node::getBoundsInScreen)
        Log.i("DieterPerformance", "nativeTap label=$label bounds=$bounds")
        val downTime = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action,
                bounds.exactCenterX(), bounds.exactCenterY(), 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            try { assertTrue("Native tap on $label", instrumentation.uiAutomation.injectInputEvent(event, true)) }
            finally { event.recycle() }
            if (action == MotionEvent.ACTION_DOWN) SystemClock.sleep(30)
        }
    }

    private fun awaitNode(description: String = "selected navigation control", find: (AccessibilityNodeInfo) -> AccessibilityNodeInfo?): AccessibilityNodeInfo {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            // API 37 can retain the underlying window's old selection after
            // dismissing a modal window. Query current semantics, not that cache.
            if (android.os.Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
            instrumentation.uiAutomation.rootInActiveWindow?.let { root ->
                if (android.os.Build.VERSION.SDK_INT < 33) root.refresh()
                val target = find(root)
                // Release-mode startup checks may display an update prompt.
                // Dismiss it through its visible control during setup only;
                // never download an update or silently alter a measured run.
                if (target == null && !measuring) {
                    findClickable(root, "Later")?.let { tap(it, "Later") }
                }
                target
            }?.let { return it }
            SystemClock.sleep(50)
        }
        val screenshot = instrumentation.uiAutomation.takeScreenshot()
        val file = java.io.File(activity.getExternalFilesDir(null), "navigation-failure.png")
        file.outputStream().use { screenshot?.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        screenshot?.recycle()
        instrumentation.uiAutomation.rootInActiveWindow?.let { root ->
            for (label in listOf("Chats", "Projects", "Tools", "Terminal", "Close sheet")) {
                val node = findClickable(root, label)
                Log.i("DieterPerformance", "failedTarget label=$label selected=${node?.isSelected} " +
                    "bounds=${node?.let { Rect().also(it::getBoundsInScreen) }}")
            }
        }
        error("Expected $description did not appear; screenshot=$file")
    }

    private fun findClickable(root: AccessibilityNodeInfo, label: String): AccessibilityNodeInfo? {
        var visited = 0
        // The bottom navigation is last in the window's traversal order.
        // Stop at its matching control instead of synchronously scanning every
        // row above it. Compose's virtual provider does not implement Android's
        // native text-search query, so retain observed-node traversal.
        fun visit(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (++visited > 1_024) return null
            if (node.packageName?.toString() == activity.packageName && node.isVisibleToUser &&
                (node.text?.toString() == label || node.contentDescription?.toString() == label)) {
                var clickable: AccessibilityNodeInfo? = node
                while (clickable != null) {
                    if ((clickable.isClickable || clickable.isSelected) && clickable.isEnabled) {
                        return clickable
                    }
                    clickable = clickable.parent
                }
            }
            for (index in node.childCount - 1 downTo 0) {
                node.getChild(index)?.let { visit(it) }?.let { return it }
            }
            return null
        }
        // Selected tabs intentionally remove their click action in Compose's
        // accessibility tree; accept selected nodes when verifying the result.
        // Route names also occur in page headings and widget previews. The
        // observed bottom navigation control is the lowest matching target.
        return visit(root)
    }

    private companion object {
        // Production-mode emulator regression budgets; physical 60/120 Hz
        // qualification remains a separate measurement.
        const val SEVERE_FRAME_MS = 500
        const val P95_FRAME_MS = 120
    }
}
