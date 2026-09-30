package com.dbpprt.dieter.e2e

import android.Manifest
import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.activity.ActivityItem
import com.dbpprt.dieter.core.activity.ActivityKind
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

/** Interprets validated JSON with native Compose synchronization and assertions. */
class FlowTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain
        .outerRule(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
        .around(compose)
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val container get() = (compose.activity.application as DieterApplication).container
    private val variables = mutableMapOf<String, String>()
    private lateinit var evidence: File
    private lateinit var events: File

    @Test fun runFlow() {
        check(instrumentation.targetContext.packageName == "com.dbpprt.dieter.e2e")
        val plan = JSONObject(File(instrumentation.targetContext.filesDir, "plan.json").readText())
        check(plan.getInt("version") == 1)
        val case = plan.getJSONObject("case")
        evidence = File(instrumentation.targetContext.filesDir, "e2e").apply { mkdirs() }
        events = File(evidence, "events.jsonl")
        val steps = case.getJSONArray("steps")
        check(steps.length() in 1..100)
        try {
            for (index in 0 until steps.length()) {
                val step = steps.getJSONObject(index)
                val started = SystemClock.elapsedRealtime()
                val action = step.keys().asSequence().single { it != "line" }
                emit(index, step, action, "started", 0)
                try {
                    when (action) {
                        "launch" -> bindFixture(case.getString("fixture"))
                        "tap" -> ready(step.getJSONObject(action)).performClick()
                        "type" -> {
                            val field = step.getJSONObject(action)
                            ready(field).performTextReplacement(resolve(field.getString("value")))
                        }
                        "expect" -> expect(step.getJSONObject(action))
                        "scroll" -> {
                            val scroll = step.getJSONObject(action)
                            node(scroll.getJSONObject("within")).performScrollToNode(matcher(scroll.getJSONObject("until")))
                        }
                        "press" -> {
                            check(step.getString(action) == "back")
                            compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
                        }
                        "screenshot" -> capture(step.getString(action))
                        "probe" -> probe(step.getString(action))
                        else -> error("Unsupported action $action")
                    }
                    emit(index, step, action, "passed", SystemClock.elapsedRealtime() - started)
                } catch (error: Throwable) {
                    emit(index, step, action, "failed", SystemClock.elapsedRealtime() - started)
                    throw AssertionError("${case.getString("source")}:${step.getInt("line")}: $action failed", error)
                }
            }
            capture("final")
        } catch (error: Throwable) {
            runCatching { capture("failure") }
            throw error
        } finally {
            IsolatedCore.disconnect(container)
        }
    }

    private fun resolve(value: String): String = Regex("\\$\\{([^}]+)\\}").replace(value) {
        variables[it.groupValues[1]] ?: error("Unbound fixture value ${it.groupValues[1]}")
    }
    private fun matcher(target: JSONObject): SemanticsMatcher = when {
        target.has("id") -> hasTestTag(resolve(target.getString("id")))
        target.has("description") -> hasContentDescription(resolve(target.getString("description")))
        else -> hasText(resolve(target.getString("text")))
    }
    private fun node(target: JSONObject): SemanticsNodeInteraction {
        val match = matcher(target)
        compose.waitUntil(15_000) {
            val count = compose.onAllNodes(match).fetchSemanticsNodes().size
            check(count <= 1) { "Ambiguous target: $target ($count matches)" }
            count == 1
        }
        return compose.onNode(match)
    }
    private fun ready(target: JSONObject): SemanticsNodeInteraction {
        val result = node(target)
        compose.waitUntil(15_000) { runCatching { result.assertIsDisplayed().assertIsEnabled() }.isSuccess }
        return result
    }
    private fun expect(target: JSONObject) {
        if (target.has("visible") && !target.getBoolean("visible")) {
            compose.waitUntil(15_000) { compose.onAllNodes(matcher(target)).fetchSemanticsNodes().isEmpty() }
            return
        }
        val result = node(target)
        compose.waitUntil(15_000) {
            runCatching {
                if (target.optBoolean("visible")) result.assertIsDisplayed()
                if (target.has("enabled")) {
                    if (target.getBoolean("enabled")) result.assertIsEnabled() else result.assertIsNotEnabled()
                }
                if (target.has("selected")) {
                    if (target.getBoolean("selected")) result.assertIsSelected() else result.assertIsNotSelected()
                }
                if (target.has("value")) result.assert(SemanticsMatcher.expectValue(
                    SemanticsProperties.EditableText, AnnotatedString(resolve(target.getString("value")))))
            }.isSuccess
        }
    }
    private fun emit(index: Int, step: JSONObject, action: String, status: String, elapsed: Long) {
        events.appendText(JSONObject().put("step", index).put("line", step.getInt("line"))
            .put("action", action).put("status", status).put("elapsedMs", elapsed).toString() + "\n")
    }
    private fun capture(name: String) {
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot()) { "Screenshot unavailable" }
        File(evidence, "$name.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
        val roots = compose.onAllNodes(isRoot())
        File(evidence, "$name.txt").writeText((0 until roots.fetchSemanticsNodes().size).joinToString("\n") { roots[it].printToString() })
    }

    private fun bindFixture(recipe: String) {
        val args = InstrumentationRegistry.getArguments()
        val connected = IsolatedCore.connect(container)
        val machineId = requireNotNull(args.getString("isolatedMachineId"))
        runBlocking {
            withTimeout(30_000) {
                container.core.connection.machines.first { directory -> directory.all.any { it.id == machineId && it.online(directory.evaluatedAt) } }
            }
        }
        // Machine rows are keyed by daemon ID.
        variables["fixture.endpointId"] = machineId
        if (recipe == "activity") {
            val board = connected.boards.values.flatten().first { it.id == args.getString("isolatedBoardId") }
            val prefix = "Activity journey"
            variables["fixture.activityPrefix"] = prefix
            val cards = listOf(false, true).map { chat ->
                IsolatedCore.createConversation(container, CreateConversationRequest(project_id = board.project_id, board_id = if (chat) "" else board.id, title = "$prefix ${if (chat) "chat" else "card"}", lane = "running", prompt = "mock-activity-reply", provider = "mock", model = "mock", workspace_mode = "project"), chat)
            }
            variables["fixture.cardId"] = cards[0].id
            variables["fixture.chatId"] = cards[1].id
            runBlocking {
                withTimeout(30_000) {
                    container.core.workspace.state.first { view ->
                        cards.all { expected -> view.card(expected.id)?.let { it.runtime.isNotBlank() && it.runtime_updated_at.isNotBlank() } == true }
                    }
                }
            }
        }
    }
    private fun activity(): List<ActivityItem> = runBlocking { container.core.activity().first() }
    private fun probe(name: String) {
        when (name) {
            "machine-telemetry" -> {
                val information = runBlocking {
                    container.core.onMachine(variables.getValue("fixture.endpointId")) { it.GetMachineInformation().execute(Unit) }
                }
                check(information.hostname.isNotBlank() && information.os_name.isNotBlank())
                check(information.logical_cpu_count > 0 && information.memory_total_bytes > 0)
                check(information.processes.any { it.kind == "daemon" })
            }
            "activity-replies-unread" -> compose.waitUntil(15_000) {
                val entries = activity()
                listOf("fixture.cardId", "fixture.chatId").all { key ->
                    entries.any { it.card.id == variables.getValue(key) && it.kind == ActivityKind.UNREAD && it.kind.needsYou }
                }
            }
            "activity-card-seen", "activity-chat-seen" -> compose.waitUntil(15_000) {
                val id = variables.getValue(if (name == "activity-card-seen") "fixture.cardId" else "fixture.chatId")
                activity().any {
                    it.card.id == id && it.card.response_seq > 0 && it.card.seen_response_seq == it.card.response_seq && !it.kind.needsYou
                }
            }
            else -> error("Unsupported probe $name")
        }
    }
}
