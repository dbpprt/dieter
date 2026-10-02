package com.dbpprt.dieter.widget

import android.Manifest
import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.R
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.e2e.IsolatedCore
import com.dbpprt.dieter.e2e.Evidence
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

/** Exercises real quota streams, AppWidgetService, RemoteViews and refresh PendingIntents. */
class WidgetUsageEndToEndTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain.outerRule(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
        .around(compose).around(com.dbpprt.dieter.e2e.FailureEvidence())
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private var hostScreen: ActivityScenario<ComponentActivity>? = null
    private lateinit var widgetView: AppWidgetHostView
    private lateinit var host: AppWidgetHost
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    @Test fun usageWidgetsLoadLiveDataAndRefreshWhileAppOnlySyncIsSleeping() {
        check(context.packageName == "com.dbpprt.dieter.e2e")
        val container = (compose.activity.application as DieterApplication).container
        val core = container.core
        val originalMode = container.policy.mode.value
        val widgets = AppWidgetManager.getInstance(context)
        val userId = shell("am get-current-user").trim().toInt()
        val ids = mutableListOf<Int>()
        shell("appwidget grantbind --package ${context.packageName} --user $userId")
        try {
            assertTrue("Fresh install starts without widget cache", WidgetUsagePrefs.cachedGroups(context).isEmpty())
            IsolatedCore.connect(container)
            runBlocking { withTimeout(30_000) {
                core.quotas.view.first { view -> view.live && view.groups.any { group ->
                    group.accounts.any { account -> account.display_email == "widget@example.test" && account.windows.any { it.remaining_percent == 72 } }
                } }
            } }
            // No refresh tap and no demo cache seeding: the normal live stream
            // must populate widget storage even before a widget is added.
            compose.waitUntil(10_000) {
                WidgetUsagePrefs.cachedGroups(context).any { group ->
                    group.accounts.any { account -> account.display_email == "widget@example.test" && account.windows.any { it.remaining_percent == 72 } }
                }
            }
            instrumentation.runOnMainSync {
                host = AppWidgetHost(context, 261012)
                host.startListening()
            }
            for ((provider, size) in listOf(
                DieterUsageWidgetProvider::class.java to (360 to 360),
                DieterUsageSmallWidgetProvider::class.java to (160 to 180),
            )) {
                val (width, height) = size
                instrumentation.runOnMainSync {
                    widgetId = host.allocateAppWidgetId()
                    ids += widgetId
                    assertTrue(widgets.bindAppWidgetIdIfAllowed(widgetId, ComponentName(context, provider), options(width, height)))
                }
                showWidget(width, height)
                awaitText("72%")
                if (width > 180) awaitText("widget@example.test")
                // Wait for the initial APPWIDGET_UPDATE refresh to finish.
                compose.waitUntil(12_000) { "Refreshing…" !in widgetTexts() }
                assertFalse("Initial fetch succeeded: ${widgetTexts()}", "Couldn’t refresh" in widgetTexts())
                capture(if (width > 180) "usage-live-large" else "usage-live-small")
            }

            instrumentation.runOnMainSync {
                container.policy.setMode(BackgroundMode.APP_ONLY)
                container.policy.setForeground(false)
            }
            runBlocking { withTimeout(12_000) { core.connection.state.first { it.phase == ConnectionPhase.DISCONNECTED } } }
            awaitText("72%") // Pausing the live stream retains the last numbers.
            val lastFetch = WidgetUsagePrefs.fetchedAt(context)
            onView(withId(R.id.widget_usage_refresh)).perform(click())
            compose.waitUntil(15_000) { WidgetUsagePrefs.fetchedAt(context) > lastFetch }
            awaitText("72%")
            runBlocking { withTimeout(12_000) { core.connection.state.first { it.phase == ConnectionPhase.DISCONNECTED } } }
            compose.waitUntil(12_000) { "Refreshing…" !in widgetTexts() }
            assertFalse("Refresh succeeded: ${widgetTexts()}", "Couldn’t refresh" in widgetTexts())
            assertEquals(BackgroundMode.APP_ONLY, container.policy.mode.value)
            assertTrue(container.policy.desired.value)
            capture("usage-refreshed-while-sleeping")

            // Completing the usage refresh must retain another widget's lease.
            runBlocking { withTimeout(12_000) {
                container.policy.withWidgetRefresh {
                    core.connection.state.first { it.phase == ConnectionPhase.CONNECTED }
                    assertTrue(DieterUsageWidgetProvider.fetch(context, requestRefresh = false))
                    delay(250)
                    assertEquals(ConnectionPhase.CONNECTED, core.connection.state.value.phase)
                }
                core.connection.state.first { it.phase == ConnectionPhase.DISCONNECTED }
            } }

            // A new widget must initiate a bounded fetch from a cold cache,
            // even when only the home screen is open.
            WidgetUsagePrefs.saveCache(context, emptyList(), 0)
            instrumentation.runOnMainSync {
                widgetId = host.allocateAppWidgetId()
                ids += widgetId
                assertTrue(widgets.bindAppWidgetIdIfAllowed(widgetId,
                    ComponentName(context, DieterUsageWidgetProvider::class.java), options(360, 360)))
            }
            showWidget(360, 360)
            awaitText("72%")
            awaitText("widget@example.test")
            runBlocking { withTimeout(12_000) { core.connection.state.first { it.phase == ConnectionPhase.DISCONNECTED } } }
            capture("usage-initial-fetch-while-sleeping")

            // An unavailable connection must not replace useful cached data
            // with the quota store's empty initial state or report success.
            IsolatedCore.disconnect(container)
            val cached = WidgetUsagePrefs.cachedGroups(context) to WidgetUsagePrefs.fetchedAt(context)
            assertFalse(runBlocking { DieterUsageWidgetProvider.fetch(context, requestRefresh = true) })
            assertEquals(cached, WidgetUsagePrefs.cachedGroups(context) to WidgetUsagePrefs.fetchedAt(context))

            WidgetUsagePrefs.saveCache(context, emptyList(), 0)
            DieterUsageWidgetProvider.updateAll(context)
            awaitText("No usage yet")
            instrumentation.runOnMainSync {
                assertEquals(View.GONE, widgetView.findViewById<View>(R.id.widget_usage_list).visibility)
                assertEquals(View.VISIBLE, widgetView.findViewById<View>(R.id.widget_usage_empty).visibility)
            }
            capture("usage-empty-state")
        } finally {
            hostScreen?.close()
            if (::host.isInitialized) instrumentation.runOnMainSync {
                host.stopListening()
                ids.forEach(host::deleteAppWidgetId)
                host.deleteHost()
            }
            shell("appwidget revokebind --package ${context.packageName} --user $userId")
            instrumentation.runOnMainSync { container.policy.setMode(originalMode) }
            IsolatedCore.disconnect(container)
        }
    }

    private fun options(width: Int, height: Int) = Bundle().apply {
        putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, width)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, width)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, height)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, height)
    }

    private fun showWidget(width: Int, height: Int) {
        hostScreen?.close()
        hostScreen = ActivityScenario.launch<ComponentActivity>(Intent(context, ComponentActivity::class.java))
        hostScreen!!.onActivity { activity ->
            val widgets = AppWidgetManager.getInstance(context)
            widgets.updateAppWidgetOptions(widgetId, options(width, height))
            widgetView = host.createView(activity, widgetId, widgets.getAppWidgetInfo(widgetId))
            val density = activity.resources.displayMetrics.density
            val root = FrameLayout(activity).apply {
                setBackgroundColor(0xFFCBD4E3.toInt())
                addView(widgetView, FrameLayout.LayoutParams((width * density).toInt(), (height * density).toInt(), Gravity.CENTER))
            }
            activity.setContentView(root)
        }
        instrumentation.waitForIdleSync()
    }

    private fun widgetTexts(): List<String> {
        var texts = emptyList<String>()
        instrumentation.runOnMainSync {
            fun descendants(view: View): List<String> = when (view) {
                is TextView -> listOf(view.text.toString())
                is ViewGroup -> (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) }
                else -> emptyList()
            }
            texts = descendants(widgetView)
        }
        return texts
    }
    private fun awaitText(text: String) = compose.waitUntil(20_000) { text in widgetTexts() }
    private fun awaitAbsent(text: String) = compose.waitUntil(20_000) { text !in widgetTexts() }
    private fun capture(name: String) {
        instrumentation.waitForIdleSync()
        // RemoteViews can have new text before the launcher window has drawn
        // it. Wait for the frame and activity transition before taking pixels.
        val drawn = java.util.concurrent.CountDownLatch(1)
        instrumentation.runOnMainSync {
            widgetView.viewTreeObserver.registerFrameCommitCallback { drawn.countDown() }
            widgetView.invalidate()
        }
        check(drawn.await(3, java.util.concurrent.TimeUnit.SECONDS)) { "Widget frame was not drawn" }
        instrumentation.uiAutomation.waitForIdle(300, 3_000)
        Evidence.display("$name.png")
        Evidence.text("$name.txt", widgetTexts().joinToString("\n"))
    }
    private fun shell(command: String): String =
        instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes().decodeToString() }
        }
}
