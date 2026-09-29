package com.dbpprt.dieter.ui

import android.Manifest
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

/** Real system Sharesheet -> real Activity/composer -> isolated owning daemon. */
class TaskCaptureEndToEndTest {
    private val compose = createEmptyComposeRule()
    @get:Rule val rules: RuleChain = RuleChain.outerRule(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
        .around(compose).around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test fun sharesheetAndInboxUseOneDurableComposer() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val context = instrumentation.targetContext
        instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val container = (context.applicationContext as DieterApplication).container
        val manager = container.connectionManager
        val endpoint = DieterEndpoint("task_capture_gateway", "Capture fixture",
            arguments.getString("isolatedGatewayHost") ?: "10.0.2.2",
            arguments.getString("isolatedGatewayPort")!!.toInt())
        container.repository.setAccessToken(endpoint, arguments.getString("isolatedGatewayToken")!!)
        manager.updateEndpoints(listOf(endpoint), selectedGatewayId = endpoint.id)
        manager.connect(); manager.onAppForegrounded()
        val connected = runBlocking { withTimeout(30_000) { manager.state.first {
            it.phase == ConnectionPhase.CONNECTED && it.boards.isNotEmpty() && it.harnesses.any { h -> h.modelsCount > 0 }
        } } }
        val board = connected.boards.first()
        val project = connected.projects.first { it.id == board.projectId }
        runBlocking { manager.ensureCheckoutRoute(project.id, project.checkoutsList.first().id) }

        val file = File(context.filesDir, "capture-fixture/screenshot.png").apply { parentFile!!.mkdirs() }
        Bitmap.createBitmap(80, 120, Bitmap.Config.ARGB_8888).apply {
            eraseColor(Color.rgb(70, 120, 210))
            file.outputStream().use { compress(Bitmap.CompressFormat.PNG, 100, it) }
            recycle()
        }
        val bytes = file.readBytes()
        val uri = Uri.parse("content://${context.packageName}.capture-fixture/screenshot.png")
        compose.runOnIdle {
            currentActivity().startActivity(Intent().setClassName(context.packageName, "com.dbpprt.dieter.fixtures.CaptureShareActivity")
                .putExtra("uri", uri.toString()))
        }
        var senderButton: AccessibilityNodeInfo? = null
        val senderDeadline = System.currentTimeMillis() + 10_000
        while (senderButton == null && System.currentTimeMillis() < senderDeadline) {
            senderButton = find(instrumentation.uiAutomation.rootInActiveWindow) { it.text?.toString()?.equals("Share screenshot", ignoreCase = true) == true }
            if (senderButton == null) Thread.sleep(100)
        }
        assertTrue(requireNotNull(senderButton).performAction(AccessibilityNodeInfo.ACTION_CLICK))
        val deadline = System.currentTimeMillis() + 15_000
        var clicked = false
        while (!clicked && System.currentTimeMillis() < deadline) {
            val node = find(instrumentation.uiAutomation.rootInActiveWindow) {
                it.text?.toString() == "Dieter task capture" && it.packageName?.toString() != context.packageName
            }
            if (node != null) {
                var target: AccessibilityNodeInfo? = node
                while (target != null && !target.isClickable) target = target.parent
                instrumentation.uiAutomation.waitForIdle(250, 2000)
                capture("capture-system-sharesheet.png")
                clicked = target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
            }
            if (!clicked) Thread.sleep(100)
        }
        if (!clicked) capture("capture-missing-share-target.png")
        assertTrue("Dieter must be selectable in the real Android Sharesheet", clicked)
        compose.waitUntil(15_000) { compose.onAllNodesWithTag("capture-project-${project.id}").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        capture("capture-project-picker.png")
        compose.onNodeWithTag("capture-project-${project.id}").performClick()
        compose.waitUntil(15_000) { compose.onAllNodesWithTag("conversation-prompt").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        compose.onNodeWithTag("conversation-prompt").assertTextContains("Review this screenshot")
        compose.waitUntil(15_000) { container.taskCaptures.drafts.any { it.attachments.size == 1 && !it.importing } }
        compose.onNodeWithTag("composer-attachment-0").performScrollTo().assertIsDisplayed()
        capture("capture-shared-attachment.png")
        compose.onNodeWithText("Preview screenshot.png").performScrollTo().performClick()
        compose.onNodeWithText("Close preview").assertIsDisplayed().performClick()
        compose.onNodeWithTag("conversation-title").performScrollTo().performTextReplacement("Screenshot capture regression")
        compose.onNodeWithText("Quick task", useUnmergedTree = true).performClick()
        compose.onNodeWithTag("quick-task-story").assertTextContains("Review this screenshot")
        compose.onNodeWithTag("composer-attachment-0").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("More options").performScrollTo().performClick()
        compose.onNodeWithTag("conversation-title").assertTextContains("Screenshot capture regression")

        // Activity recreation must not replay the share or lose the shared composer.
        instrumentation.runOnMainSync { currentActivity().recreate() }
        compose.waitUntil(15_000) { compose.onAllNodesWithTag("conversation-title").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        compose.onNodeWithTag("conversation-title").assertTextContains("Screenshot capture regression")
        assertEquals(1, container.taskCaptures.drafts.single { it.title == "Screenshot capture regression" }.attachments.size)
        compose.onAllNodesWithText("Save")[0].performClick()
        val created = runBlocking { withTimeout(30_000) { manager.state.first { state ->
            state.cards.count { it.title == "Screenshot capture regression" } == 1 &&
                state.cards.any { it.title == "Screenshot capture regression" && it.ownerDaemonId.isNotBlank() }
        }.cards.single { it.title == "Screenshot capture regression" } } }
        val conversation = runBlocking { container.repository.conversation(created.id) }.conversation
        assertArrayEquals(bytes, conversation.draftAttachmentsList.single().data.toByteArray())
        assertEquals(project.id, created.projectId)
        assertEquals(board.id, created.boardId)

        compose.runOnIdle { ViewModelProvider(currentActivity())[DieterViewModel::class.java].navigate(Destination.ACTIVITY) }
        compose.onNodeWithTag("inbox-new-task").assertIsDisplayed().performClick()
        compose.onNodeWithTag("capture-project-${project.id}").performClick()
        compose.onNodeWithTag("conversation-prompt").performTextInput("Created from Inbox")
        compose.onNodeWithTag("conversation-title").performTextReplacement("Inbox capture regression")
        capture("capture-inbox-composer.png")
        compose.onAllNodesWithText("Save")[0].performClick()
        runBlocking { withTimeout(30_000) { manager.state.first { state ->
            state.cards.count { it.title == "Inbox capture regression" && it.ownerDaemonId.isNotBlank() } == 1
        } } }
        assertFalse(container.taskCaptures.drafts.any { it.title == "Inbox capture regression" })
    }

    private fun currentActivity(): MainActivity = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
        .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).filterIsInstance<MainActivity>().single()

    private fun find(node: AccessibilityNodeInfo?, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        node ?: return null
        if (predicate(node)) return node
        for (index in 0 until node.childCount) find(node.getChild(index), predicate)?.let { return it }
        return null
    }

    private fun capture(name: String) {
        val directory = File(InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
            ?: requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)).path)
        directory.mkdirs()
        fun describe(node: AccessibilityNodeInfo?, depth: Int = 0): String {
            node ?: return ""
            return "${" ".repeat(depth)}${node.className}: ${node.text} / ${node.contentDescription} [${node.viewIdResourceName}]\n" +
                (0 until node.childCount).joinToString("") { describe(node.getChild(it), depth + 1) }
        }
        File(directory, "$name.hierarchy.txt").writeText(describe(InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow))
        File(directory, name).outputStream().use {
            requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()).compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
