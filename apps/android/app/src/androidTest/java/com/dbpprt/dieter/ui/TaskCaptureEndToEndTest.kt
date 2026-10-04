package com.dbpprt.dieter.ui

import android.Manifest
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
import com.dbpprt.dieter.core.composition.task
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.e2e.IsolatedCore
import com.dbpprt.dieter.e2e.Evidence
import kotlinx.coroutines.flow.first
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
        val context = instrumentation.targetContext
        instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val container = (context.applicationContext as DieterApplication).container
        val connected = IsolatedCore.connect(container)
        val board = connected.boards.values.flatten().first()
        val project = connected.projects.first { it.id == board.project_id }
        IsolatedCore.harnesses(container, project.checkouts.first().daemon_id)

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
        var expanded = false
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
            } else if (!expanded) {
                // Samsung's chooser initially shows a short ranked row. Open
                // its observed More control to reach the isolated fixture app;
                // never select the operator's separately installed Dieter.
                val more = find(instrumentation.uiAutomation.rootInActiveWindow) {
                    it.text?.toString() == "More" && it.packageName?.toString() == "com.android.intentresolver"
                }
                if (more != null) {
                    var target: AccessibilityNodeInfo? = more
                    while (target != null && !target.isClickable) target = target.parent
                    capture("capture-expand-system-sharesheet.png")
                    expanded = target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
                }
            }
            if (!clicked) Thread.sleep(100)
        }
        if (!clicked) capture("capture-missing-share-target.png")
        assertTrue("Dieter must be selectable in the real Android Sharesheet", clicked)
        // Samsung groups multiple share activities under the app label and
        // opens a second picker. Select the observed capture activity there.
        val activityDeadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < activityDeadline) {
            val root = instrumentation.uiAutomation.rootInActiveWindow
            if (root?.packageName?.toString() == context.packageName) break
            val alternative = find(root) { it.text?.toString() == "Capture test alternative" }
            if (alternative != null) {
                val captureActivity = find(root) { it.text?.toString() == "Dieter task capture" }
                var target: AccessibilityNodeInfo? = captureActivity
                while (target != null && !target.isClickable) target = target.parent
                capture("capture-system-activity-picker.png")
                assertTrue("Select the isolated capture activity", target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true)
                break
            }
            Thread.sleep(100)
        }
        compose.waitUntil(15_000) { compose.onAllNodesWithTag("capture-project-${project.id}").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        capture("capture-project-picker.png")
        compose.onNodeWithTag("capture-project-${project.id}").performClick()
        compose.waitUntil(15_000) { compose.onAllNodesWithTag("conversation-prompt").fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty() }
        compose.onNodeWithTag("conversation-prompt").assertTextContains("Review this screenshot")
        compose.waitUntil(15_000) { container.taskCaptures.view.value.drafts.any { it.task.attachments.size == 1 && !it.importing } }
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
        assertEquals(1, container.taskCaptures.view.value.drafts.single { it.task.title == "Screenshot capture regression" }.task.attachments.size)
        compose.onAllNodesWithText("Save")[0].performClick()
        val created = IsolatedCore.awaitCard(container) { it.title == "Screenshot capture regression" && it.owner_daemon_id.isNotBlank() }
        assertEquals(1, container.core.workspace.state.value.allItems.count { it.title == "Screenshot capture regression" })
        val conversation = requireNotNull(IsolatedCore.conversation(container, created.id, created.owner_daemon_id).conversation)
        assertArrayEquals(bytes, conversation.draft_attachments.single().data_.toByteArray())
        assertEquals(project.id, created.project_id)
        assertEquals(board.id, created.board_id)

        compose.runOnIdle { ViewModelProvider(currentActivity())[DieterViewModel::class.java].navigate(Destination.ACTIVITY) }
        compose.onNodeWithTag("inbox-new-task").assertIsDisplayed().performClick()
        compose.onNodeWithTag("capture-project-${project.id}").performClick()
        compose.onNodeWithTag("conversation-prompt").performTextInput("Created from Inbox")
        compose.onNodeWithTag("conversation-title").performTextReplacement("Inbox capture regression")
        capture("capture-inbox-composer.png")
        compose.onAllNodesWithText("Save")[0].performClick()
        IsolatedCore.awaitCard(container) { it.title == "Inbox capture regression" && it.owner_daemon_id.isNotBlank() }
        assertEquals(1, container.core.workspace.state.value.allItems.count { it.title == "Inbox capture regression" })
        assertFalse(container.taskCaptures.view.value.drafts.any { it.task.title == "Inbox capture regression" })
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
        fun describe(node: AccessibilityNodeInfo?, depth: Int = 0): String {
            node ?: return ""
            return "${" ".repeat(depth)}${node.className}: ${node.text} / ${node.contentDescription} [${node.viewIdResourceName}]\n" +
                (0 until node.childCount).joinToString("") { describe(node.getChild(it), depth + 1) }
        }
        Evidence.text("$name.hierarchy.txt", describe(InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow))
        Evidence.display(name)
    }
}
