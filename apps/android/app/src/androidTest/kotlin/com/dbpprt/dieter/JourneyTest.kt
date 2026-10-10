package com.dbpprt.dieter

import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test

class JourneyTest {
    @get:Rule val compose = createEmptyComposeRule()

    /** Opens the app against the isolated fixture the pipeline wrote into its private files. */
    private fun fixtureIntent(): Intent {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val fixture = JSONObject(File(context.filesDir, "fixture.json").readText())
        return Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra("fixture_url", "http://127.0.0.1:${fixture.getString("port")}")
            putExtra("fixture_token", fixture.getString("token"))
        }
    }

    /** Text and a screenshot shared from another app open a prefilled new task, once. */
    @Test
    fun sharedItemsStartATask() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val screenshot =
            File(context.cacheDir, "updates/shared-layout.png").apply {
                parentFile!!.mkdirs()
                outputStream().use {
                    Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
                        .apply { eraseColor(android.graphics.Color.rgb(98, 182, 203)) }
                        .compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            }
        val intent =
            fixtureIntent().apply {
                action = Intent.ACTION_SEND
                type = "image/png"
                putExtra(
                    Intent.EXTRA_STREAM,
                    FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.updates",
                        screenshot,
                    ),
                )
                putExtra(Intent.EXTRA_TEXT, "Tighten the shared layout")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        ActivityScenario.launch<MainActivity>(intent).use { scenario ->
            waitForTag("task-prompt")
            waitForText("Tighten the shared layout")
            waitForText("shared-layout.png")
            capture("android-share-new-task")
            // Recreation keeps the one shared draft; the intent is not read again.
            scenario.recreate()
            waitForText("shared-layout.png")
            compose.onAllNodesWithText("shared-layout.png").assertCountEquals(1)
            compose.onNodeWithTag("chrome-start-working").performClick()
            waitForText("Mock harness received: Tighten the shared layout", substring = true)
            waitForText("shared-layout.png")
            capture("android-share-conversation")
        }
    }

    @Test
    fun sharedTaskJourney() {
        ActivityScenario.launch<MainActivity>(fixtureIntent()).use { scenario ->
            waitForText("Design the mobile workspace")
            assertInboxLayout()
            capture("android-inbox")
            pullToRefresh(scenario, "inbox-refresh")
            assertInboxLayout()
            compose.onNodeWithTag("nav-projects").performClick()
            waitForText("Isolated E2E")
            waitForText("Main")
            capture("android-projects")
            compose.onNodeWithText("Main").performClick()
            waitForTag("lane-1")
            waitForText("Design the mobile workspace")
            capture("android-board")
            compose.onNodeWithText("Design the mobile workspace").performClick()
            waitForText("Your board stays within reach", substring = true)
            capture("android-task")
            compose.onNodeWithTag("chrome-conversation-menu").performClick()
            compose.onNodeWithTag("menu-pane-subagents").performClick()
            waitForText("Layout scout")
            capture("android-subagents")
            compose.onNodeWithTag("chrome-back").performClick()
            waitForText("Your board stays within reach", substring = true)
            compose.onNodeWithTag("chrome-back").performClick()
            waitForTag("chrome-new-task")
            compose.onNodeWithTag("chrome-new-task").performClick()
            waitForTag("task-title")
            compose.onNodeWithTag("task-title").performTextInput("A shared mobile conversation")
            compose
                .onNodeWithTag("task-prompt")
                .performTextInput("Explain how this task stays in one durable conversation.")
            scenario.recreate()
            waitForText("A shared mobile conversation")
            compose
                .onNodeWithText("Explain how this task stays in one durable conversation.")
                .assertExists()
            capture("android-new-task")
            compose.onNodeWithTag("chrome-start-working").performClick()
            waitForText("Mock harness received:", substring = true)
            capture("android-conversation")
            compose
                .onNodeWithTag("message-input")
                .performTextInput("Keep the same task and add the next step.")
            scenario.recreate()
            waitForText("Keep the same task and add the next step.")
            compose.onNodeWithTag("send-message").performClick()
            waitForText("Mock harness received: Keep the same task", substring = true)
            waitForTag("move-review")
            compose.onNodeWithTag("move-review").performClick()
            compose.onNodeWithTag("chrome-back").performClick()
            waitForTag("lane-2")
            compose.onNodeWithTag("lane-2").performClick()
            waitForText("A shared mobile conversation")
            capture("android-review")
            compose.onNodeWithTag("nav-inbox").performClick()
            compose.onNodeWithTag("inbox-filter-review").performClick()
            waitForText("Ready for review")
            compose.onAllNodesWithText("Mark done").onFirst().assertIsDisplayed()
            capture("android-inbox-review")
            compose.onNodeWithTag("inbox-filter-all").performClick()
            compose.onNodeWithTag("nav-chats").performClick()
            waitForText("Mobile release checklist")
            pullToRefresh(scenario, "chats-refresh")
            compose.onNodeWithText("Mobile release checklist").assertIsDisplayed()
            capture("android-chats")
            compose.onNodeWithTag("nav-tools").performClick()
            waitForTag("tool-machines")
            capture("android-tools")
            compose.onNodeWithTag("tool-machines").performClick()
            waitForText("Isolated E2E machine")
            capture("android-machines")
            compose.onNodeWithTag("chrome-back").performClick()
            waitForTag("tool-files")
            compose.onNodeWithTag("tool-files").performClick()
            waitForText("README.md")
            capture("android-files")
            compose.onNodeWithText("README.md").performClick()
            waitForText("One durable conversation", substring = true)
            capture("android-file-preview")
            compose.onNodeWithTag("chrome-back").performClick()
            waitForText("README.md")
            compose.onNodeWithTag("chrome-back").performClick()
            waitForTag("tool-schedules")
            compose.onNodeWithTag("tool-schedules").performClick()
            waitForText("Daily workspace review")
            capture("android-schedules")
            compose.onNodeWithTag("chrome-back").performClick()
            compose.onNodeWithTag("tools-list").performScrollToNode(hasTestTag("tool-settings"))
            compose.onNodeWithTag("tool-settings").performClick()
            waitForTag("appearance-2")
            compose.onNodeWithTag("appearance-2").performClick()
            capture("android-settings-dark")
            compose.onNodeWithTag("nav-inbox").performClick()
            waitForText("A shared mobile conversation")
            compose.onNodeWithText("A shared mobile conversation").assertIsDisplayed()
            capture("android-inbox-dark")
            compose.onNodeWithTag("nav-projects").performClick()
            waitForText("Main")
            compose.onNodeWithText("Main").performClick()
            waitForTag("lane-1")
            capture("android-board-dark")
        }
    }

    /** The real gesture must replay the core's streams, then finish its indicator. */
    private fun pullToRefresh(scenario: ActivityScenario<MainActivity>, tag: String) {
        lateinit var store: com.dbpprt.dieter.mobile.MobileStore
        scenario.onActivity { store = ViewModelProvider(it)[DieterSession::class.java].store }
        waitFor("sync before pulling $tag") { store.session.value.synced }
        val ready = AtomicBoolean(false)
        val replaying = AtomicBoolean(false)
        val replayed = AtomicBoolean(false)
        val subscription =
            store.core.observe(com.dbpprt.dieter.client.v1.Slice.SLICE_SESSION, "") { update ->
                update.session?.let {
                    if (it.synced) {
                        ready.set(true)
                        if (replaying.get()) replayed.set(true)
                    } else if (ready.get()) replaying.set(true)
                }
            }
        try {
            waitFor("session observer before pulling $tag") { ready.get() }
            compose.onNodeWithTag(tag).performTouchInput {
                // The list's bounds include scaffold padding; start below expanded app bars.
                swipe(
                    start = androidx.compose.ui.geometry.Offset(width * .5f, height * .45f),
                    end = androidx.compose.ui.geometry.Offset(width * .5f, height * .93f),
                    durationMillis = 600,
                )
            }
            waitFor("stream replay after pulling $tag") { replayed.get() }
            waitFor("refresh indicator after pulling $tag") { !store.refreshing.value }
            check(store.error.value.isEmpty()) { store.error.value }
        } finally {
            subscription.close()
        }
    }

    /** The first controls and several complete entries should fit without scrolling. */
    private fun assertInboxLayout() {
        val density =
            InstrumentationRegistry.getInstrumentation()
                .targetContext
                .resources
                .displayMetrics
                .density
        val feed = compose.onNodeWithTag("activity-feed").fetchSemanticsNode().boundsInRoot
        val search = compose.onNodeWithTag("search-field").fetchSemanticsNode().boundsInRoot
        check(search.top - feed.top < 120 * density) {
            "Inbox search is pushed down by excessive header space"
        }
        compose.onNodeWithText("Ideas for the next iteration").assertIsDisplayed()
        compose.onNodeWithText("Mobile release checklist").assertIsDisplayed()
        compose.onNodeWithText("Design the mobile workspace").assertIsDisplayed()
        compose.onNodeWithText("Make reconnect feel effortless").assertIsDisplayed()
    }

    private fun waitForText(text: String, substring: Boolean = false) =
        waitFor("text $text") {
            compose
                .onAllNodesWithText(text, substring = substring)
                .fetchSemanticsNodes()
                .isNotEmpty()
        }

    private fun waitForTag(tag: String) =
        waitFor("tag $tag") { compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty() }

    private fun waitFor(description: String, condition: () -> Boolean) {
        try {
            compose.waitUntil(60000) { condition() }
        } catch (failure: Throwable) {
            capture("android-failure")
            compose.onRoot().printToLog("JourneyFailure")
            throw AssertionError("Timed out waiting for $description", failure)
        }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        // Semantics can be committed before SurfaceFlinger presents the frame.
        // Keep full native captures (including keyboard/system bars) and let the
        // rendered buffer catch up to the verified Compose state.
        android.os.SystemClock.sleep(350)
        val directory =
            File(instrumentation.targetContext.getExternalFilesDir(null), "journey").apply {
                mkdirs()
            }
        File(directory, "$name.png").outputStream().use {
            instrumentation.uiAutomation
                .takeScreenshot()
                .compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
