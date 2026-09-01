package com.dbpprt.dieter.ui

import android.Manifest
import androidx.core.app.FrameMetricsAggregator
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.MainActivity
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
    private val composeRule = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule)

    @Test
    fun repeatedPrimaryNavigationHasNoSevereMainThreadStall() {
        composeRule.waitForIdle()
        // Warm each route once. Macrobenchmarks and real user sessions both execute optimized
        // code after this first composition; the adjacent pages are also precomposed in-app.
        listOf("nav-chats", "nav-board", "nav-terminals", "nav-board").forEach { tag ->
            composeRule.onNodeWithTag(tag).performClick()
            composeRule.waitForIdle()
        }
        val aggregator = FrameMetricsAggregator(FrameMetricsAggregator.TOTAL_DURATION)
        aggregator.add(composeRule.activity)

        repeat(4) {
            composeRule.onNodeWithTag("nav-chats").performClick()
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("nav-board").performClick()
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("nav-terminals").performClick()
            composeRule.waitForIdle()
        }

        val metrics = requireNotNull(aggregator.remove(composeRule.activity))
        val histogram = requireNotNull(metrics[FrameMetricsAggregator.TOTAL_INDEX])
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
        assertEquals("Detected a >=${SEVERE_FRAME_MS}ms UI-thread stall", 0, severeFrames)
        val p95 = orderedDurations.sorted()[(orderedDurations.size * 0.95).toInt().coerceAtMost(orderedDurations.lastIndex)]
        assertTrue("Navigation p95 was ${p95}ms", p95 < P95_FRAME_MS)
    }

    private companion object {
        const val SEVERE_FRAME_MS = 750
        const val P95_FRAME_MS = 500
    }
}
