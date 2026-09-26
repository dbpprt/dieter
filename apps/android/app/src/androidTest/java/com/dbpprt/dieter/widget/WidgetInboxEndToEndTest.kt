package com.dbpprt.dieter.widget

import android.Manifest
import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
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
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.R
import com.dbpprt.dieter.connection.BackgroundSyncMode
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.settings.DieterPalette
import com.dbpprt.dieter.v1.CreateConversationRequest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

/** Real Android AppWidgetService + RemoteViews + PendingIntents and a disposable daemon. */
class WidgetInboxEndToEndTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain.outerRule(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
        .around(compose).around(com.dbpprt.dieter.e2e.FailureEvidence())
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private var hostScreen: ActivityScenario<ComponentActivity>? = null
    private lateinit var widgetView: AppWidgetHostView
    private lateinit var host: AppWidgetHost
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    @Test fun widgetTracksInboxAndRefreshesWhileAppOnlySyncIsSleeping() {
        check(context.packageName == "com.dbpprt.dieter.e2e")
        val args = InstrumentationRegistry.getArguments()
        val endpoint = DieterEndpoint("widget-fixture", "Widget fixture", "127.0.0.1",
            requireNotNull(args.getString("isolatedGatewayPort")).toInt(), false)
        val container = (compose.activity.application as DieterApplication).container
        val manager = container.connectionManager
        val repository = container.repository
        repository.setAccessToken(endpoint, requireNotNull(args.getString("isolatedGatewayToken")))
        manager.updateEndpoints(listOf(endpoint), selectedGatewayId = endpoint.id)
        manager.connect()
        manager.onAppForegrounded()
        val userId = shell("am get-current-user").trim().toInt()
        shell("appwidget grantbind --package ${context.packageName} --user $userId")
        try {
            val connected = runBlocking { withTimeout(30_000) { manager.state.first {
                it.phase == ConnectionPhase.CONNECTED && it.boards.any { board -> board.id == args.getString("isolatedBoardId") } &&
                    it.endpointConnections.any { machine -> machine.daemonId == args.getString("isolatedMachineId") && machine.online }
            } } }
            val board = connected.boards.first { it.id == args.getString("isolatedBoardId") }
            fun create(title: String, chat: Boolean = false, prompt: String = "mock-activity-reply") = runBlocking {
                repository.createConversation(CreateConversationRequest.newBuilder().setProjectId(board.projectId)
                    .setBoardId(if (chat) "" else board.id).setTitle(title).setLane("running").setPrompt(prompt)
                    .setProvider("mock").setModel("mock").setWorkspaceMode("project").build(), chat)
            }
            val card = create("Review tablet spacing")
            val chat = create("Summarize release notes", chat = true)
            val running = create("Polish the home widget", prompt = "mock-queue-hold")
            compose.waitUntil(30_000) {
                val state = manager.state.value
                listOf(card, chat).all { expected -> (state.cards + state.chats).any { it.id == expected.id && it.responseSeq > it.seenResponseSeq } } &&
                    state.cards.any { it.id == running.id && it.runtime in setOf("starting", "running") }
            }
            val widgets = AppWidgetManager.getInstance(context)
            instrumentation.runOnMainSync {
                host = AppWidgetHost(context, 261009)
                widgetId = host.allocateAppWidgetId()
                assertTrue("Bind the real widget provider", widgets.bindAppWidgetIdIfAllowed(widgetId,
                    ComponentName(context, DieterActivityWidgetProvider::class.java), options(360, 480)))
                host.startListening()
            }
            showWidget(360, 480)
            awaitText(card.title)
            awaitText(chat.title)
            awaitText(running.title)
            awaitText("Needs attention · 2")
            capture("widget-inbox-detailed")
            container.appPreferences.setPalette(DieterPalette.ELECTRIC_BLUE)
            awaitHeaderColor(DieterPalette.ELECTRIC_BLUE.tokens.lightInt)
            capture("widget-inbox-dark")

            // Resizing changes density, never which conversations need attention.
            showWidget(200, 380)
            awaitAbsent("Needs attention · 2")
            awaitText(card.title)
            awaitText(chat.title)
            awaitText(running.title)
            capture("widget-inbox-compact")
            container.appPreferences.setPalette(DieterPalette.MONOCHROME)
            awaitHeaderColor(DieterPalette.MONOCHROME.tokens.darkBrandInt)
            capture("widget-inbox-compact-light")
            onView(withText(chat.title)).perform(click())
            compose.waitUntil(15_000) { compose.onAllNodesWithTag("message-input").fetchSemanticsNodes().isNotEmpty() }
            compose.waitUntil(15_000) { manager.state.value.chats.any { it.id == chat.id && it.seenResponseSeq >= it.responseSeq } }
            assertTrue(runBlocking { repository.card(chat.id).card.let { it.seenResponseSeq >= it.responseSeq } })
            showWidget(360, 480)
            awaitText("Needs attention · 1")
            onView(withText(card.title)).perform(click())
            compose.waitUntil(15_000) { compose.onAllNodesWithTag("message-input").fetchSemanticsNodes().isNotEmpty() }
            compose.waitUntil(15_000) { manager.state.value.cards.any { it.id == card.id && it.seenResponseSeq >= it.responseSeq } }
            showWidget(360, 480)
            awaitText("Recent · 2")
            awaitText("Finished")

            runBlocking { repository.renameCard(chat.id, "Release notes are ready") }
            awaitText("Release notes are ready") // Live push, no refresh tap.
            runBlocking { repository.archiveCard(chat.id, true) }
            awaitAbsent("Release notes are ready")
            runBlocking { repository.cancelCard(running.id) }

            manager.setBackgroundSyncMode(BackgroundSyncMode.APP_ONLY)
            runBlocking { withTimeout(10_000) { manager.state.first { it.phase == ConnectionPhase.STOPPED } } }
            runBlocking { repository.renameCard(card.id, "Spacing approved from another device") }
            assertFalse(widgetTexts().contains("Spacing approved from another device"))
            onView(withId(R.id.widget_refresh)).perform(click())
            awaitText("Spacing approved from another device")
            runBlocking { withTimeout(12_000) { manager.state.first { it.phase == ConnectionPhase.STOPPED } } }
            assertEquals(BackgroundSyncMode.APP_ONLY, manager.state.value.backgroundSyncMode)
            assertTrue(manager.state.value.desiredConnected)
            capture("widget-inbox-refreshed-offline")
            onView(withId(R.id.widget_header)).perform(click())
            compose.onNodeWithTag("nav-activity").assertIsSelected()
            compose.onNodeWithTag("activity-feed").assertIsDisplayed()
        } catch (failure: Throwable) {
            File(context.getExternalFilesDir(null), "widget-failure-state.txt").writeText(
                "phase=${manager.state.value.phase}\n" + (manager.state.value.cards + manager.state.value.chats).joinToString("\n") {
                    "${it.title}: runtime=${it.runtime}, response=${it.responseSeq}, seen=${it.seenResponseSeq}"
                })
            if (::widgetView.isInitialized) runCatching { capture("widget-failure") }.onFailure(failure::addSuppressed)
            throw failure
        } finally {
            hostScreen?.close()
            if (::host.isInitialized) instrumentation.runOnMainSync {
                host.stopListening()
                if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) host.deleteAppWidgetId(widgetId)
                host.deleteHost()
            }
            shell("appwidget revokebind --package ${context.packageName} --user $userId")
            manager.disconnect()
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
    private fun awaitHeaderColor(color: Int) = compose.waitUntil(10_000) {
        var matches = false
        instrumentation.runOnMainSync {
            matches = widgetView.findViewById<TextView>(R.id.widget_header_title)?.currentTextColor == color
        }
        matches
    }
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
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { File(context.getExternalFilesDir(null), "$name.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        File(context.getExternalFilesDir(null), "$name.txt").writeText(widgetTexts().joinToString("\n"))
    }
    private fun shell(command: String): String =
        instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes().decodeToString() }
        }
}
