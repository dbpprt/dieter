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
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.ui.ActivityKind
import com.dbpprt.dieter.ui.buildActivityEntries
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
            container.connectionManager.disconnect()
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
        val token = requireNotNull(args.getString("isolatedGatewayToken")) { "Isolated gateway required" }
        val origin = DieterEndpoint("e2e", "Isolated E2E", "127.0.0.1", args.getString("isolatedGatewayPort")!!.toInt(), false)
        val repository = container.repository
        val manager = container.connectionManager
        repository.setAccessToken(origin, token)
        manager.updateEndpoints(listOf(origin), selectedGatewayId = origin.id)
        manager.connect()
        manager.onAppForegrounded()
        val state = runBlocking { withTimeout(30_000) { manager.state.first {
            it.phase == ConnectionPhase.CONNECTED && it.boards.isNotEmpty() &&
                it.endpointConnections.any { endpoint -> endpoint.daemonId == args.getString("isolatedMachineId") && endpoint.online }
        } } }
        variables["fixture.endpointId"] = state.endpointConnections.first { it.daemonId == args.getString("isolatedMachineId") }.id
        if (recipe == "activity") {
            val board = state.boards.first { it.id == args.getString("isolatedBoardId") }
            val prefix = "Activity journey"
            variables["fixture.activityPrefix"] = prefix
            val cards = runBlocking {
                listOf(false, true).map { chat ->
                    repository.createConversation(CreateConversationRequest.newBuilder()
                        .setProjectId(board.projectId).setBoardId(if (chat) "" else board.id)
                        .setTitle("$prefix ${if (chat) "chat" else "card"}")
                        .setLane("running").setPrompt("mock-activity-reply")
                        .setProvider("mock").setModel("mock").setWorkspaceMode("project").build(), chat)
                }
            }
            variables["fixture.cardId"] = cards[0].id
            variables["fixture.chatId"] = cards[1].id
            runBlocking {
                manager.refreshMachineDirectory(includeArchivedChats = true)
                withTimeout(30_000) { manager.state.first { current -> cards.all { expected ->
                    (current.cards + current.chats).any { it.id == expected.id && it.runtime.isNotBlank() && it.runtimeUpdatedAt.isNotBlank() }
                } } }
            }
        }
    }
    private fun probe(name: String) {
        when (name) {
            "machine-telemetry" -> {
                val information = runBlocking { container.repository.machineInformationOn(variables.getValue("fixture.endpointId")) }
                check(information.hostname.isNotBlank() && information.osName.isNotBlank())
                check(information.logicalCpuCount > 0 && information.memoryTotalBytes > 0)
                check(information.processesList.any { it.kind == "daemon" })
            }
            "activity-replies-unread" -> compose.waitUntil(15_000) {
                val state = container.connectionManager.state.value
                val entries = buildActivityEntries(state.cards + state.chats)
                listOf("fixture.cardId", "fixture.chatId").all { key ->
                    entries.any { it.card.id == variables.getValue(key) && it.kind == ActivityKind.UNREAD && it.needsYou }
                }
            }
            "activity-card-seen", "activity-chat-seen" -> compose.waitUntil(15_000) {
                val id = variables.getValue(if (name == "activity-card-seen") "fixture.cardId" else "fixture.chatId")
                val state = container.connectionManager.state.value
                buildActivityEntries(state.cards + state.chats).any {
                    it.card.id == id && it.card.responseSeq > 0 && it.card.seenResponseSeq == it.card.responseSeq && !it.needsYou
                }
            }
            else -> error("Unsupported probe $name")
        }
    }
}
