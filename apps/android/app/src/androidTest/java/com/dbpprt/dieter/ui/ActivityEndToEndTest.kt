package com.dbpprt.dieter.ui

import android.Manifest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.dieterEndpointFromAddress
import com.dbpprt.dieter.v1.CreateConversationRequest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.util.UUID

/** Runs only against the explicitly supplied disposable gateway and mock harness. */
class ActivityEndToEndTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain.outerRule(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)).around(compose)

    @Test fun chatAndCardOpenFromActivityAndBackRestoresFilter() {
        val args = InstrumentationRegistry.getArguments()
        val token = args.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Requires an isolated gateway token", token.isNotBlank())
        val origin = DieterEndpoint("activity_isolated_${args.getString("isolatedGatewayPort")}", "Activity test gateway", "127.0.0.1",
            args.getString("isolatedGatewayPort")!!.toInt(), false)
        val container = (compose.activity.application as DieterApplication).container
        val repository = container.repository
        val manager = container.connectionManager
        val previous = manager.state.value
        val endpoints = previous.configuredConnections.map { dieterEndpointFromAddress(it.id, it.label, it.address) }
        repository.setAccessToken(origin, token)
        try {
            manager.updateEndpoints(listOf(origin), selectedGatewayId = origin.id)
            manager.connect()
            manager.onAppForegrounded()
            val connected = runBlocking { withTimeoutOrNull(30_000) { manager.state.first { it.phase == ConnectionPhase.CONNECTED && it.boards.any { board -> board.id == args.getString("isolatedBoardId") } } } }
                ?: error("Fixture connection: ${manager.state.value.phase}, ${manager.state.value.error}; boards=${manager.state.value.boards.size}")
            val board = connected.boards.first { it.id == args.getString("isolatedBoardId") }
            val prefix = "Activity journey ${UUID.randomUUID().toString().take(6)}"
            val cards = runBlocking {
                listOf(false, true).map { chat ->
                    repository.createConversation(CreateConversationRequest.newBuilder()
                        .setProjectId(board.projectId).setBoardId(if (chat) "" else board.id)
                        .setTitle("$prefix ${if (chat) "chat" else "card"}")
                        .setLane("running").setPrompt("Reply briefly for the Activity navigation test.")
                        .setProvider("mock").setModel("mock").setWorkspaceMode("project").build(), chat)
                }
            }
            runBlocking { manager.refreshMachineDirectory(includeArchivedChats = true) }
            val synchronized = runBlocking { withTimeoutOrNull(30_000) {
                manager.state.first { state -> cards.all { expected ->
                    (state.cards + state.chats).any { it.id == expected.id && it.runtime.isNotBlank() && it.runtimeUpdatedAt.isNotBlank() }
                } }
            } }
            check(synchronized != null) {
                "Activity sync missing: expected=${cards.map { it.id }}; actual=${(manager.state.value.cards + manager.state.value.chats).map { "${it.id}:${it.runtime}" }}; phase=${manager.state.value.phase}; error=${manager.state.value.error}"
            }
            compose.onNodeWithTag("nav-activity").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithTag("activity-feed").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Search activity").performClick()
            compose.onNodeWithTag("activity-search").performTextInput(prefix)
            cards.forEach { card ->
                compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-${card.id}"))
                compose.onNodeWithTag("activity-row-${card.id}").performClick()
                compose.waitUntil(15_000) { compose.onAllNodesWithTag("message-input").fetchSemanticsNodes().isNotEmpty() }
                compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
                compose.onNodeWithTag("nav-activity").assertIsSelected()
                compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-search"))
                compose.onNodeWithTag("activity-search").assertTextContains(prefix)
            }
        } finally {
            repository.setAccessToken(origin, null)
            manager.updateEndpoints(endpoints, selectedGatewayId = previous.activeGatewayId)
            if (previous.desiredConnected) manager.connect() else manager.disconnect()
        }
    }
}
