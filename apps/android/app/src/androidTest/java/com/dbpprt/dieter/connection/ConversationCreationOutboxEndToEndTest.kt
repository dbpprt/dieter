package com.dbpprt.dieter.connection

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.v1.CreateConversationRequest
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Android outbox -> isolated gateway/daemon -> authoritative sync coverage. */
@RunWith(AndroidJUnit4::class)
class ConversationCreationOutboxEndToEndTest {
    @Test
    fun acceptedCardReplacesItsOptimisticRow() {
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val endpoint = DieterEndpoint(
            id = "android_creation_outbox_e2e",
            label = "Isolated creation outbox gateway",
            host = arguments.getString("isolatedGatewayHost")?.takeIf(String::isNotBlank) ?: "10.0.2.2",
            port = arguments.getString("isolatedGatewayPort")?.toIntOrNull() ?: 14243,
        )
        val application = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as DieterApplication
        val manager = application.container.connectionManager
        application.container.repository.setAccessToken(endpoint, token)
        manager.updateEndpoints(listOf(endpoint), selectedGatewayId = endpoint.id)
        manager.connect()
        manager.onAppForegrounded()

        val connected = runBlocking {
            withTimeout(30_000) {
                manager.state.first { state ->
                    state.phase == ConnectionPhase.CONNECTED && state.projects.isNotEmpty() &&
                        state.boards.isNotEmpty() && state.harnesses.any { it.modelsCount > 0 }
                }
            }
        }
        val board = connected.boards.first()
        val project = connected.projects.first { it.id == board.projectId }
        val harness = connected.harnesses.first { it.modelsCount > 0 }
        val model = harness.modelsList.first()
        val title = "One Android card ${UUID.randomUUID().toString().take(8)}"

        runBlocking {
            val checkoutId = manager.ensureCheckoutRoute(
                project.id,
                requireNotNull(project.checkoutsList.firstOrNull()).id,
            )
            manager.enqueueConversation(
                CreateConversationRequest.newBuilder()
                    .setCheckoutId(checkoutId)
                    .setProjectId(project.id)
                    .setBoardId(board.id)
                    .setLane(board.lanesList.first().id)
                    .setTitle(title)
                    .setPrompt(title)
                    .setProvider(harness.id)
                    .setModel(model.id)
                    .setWorkspaceMode("project")
                    .setDeferStart(true)
                    .build(),
                chat = false,
            )
            withTimeout(30_000) {
                manager.state.first { state ->
                    state.cards.count { it.title == title } == 1 &&
                        state.cards.single { it.title == title }.ownerDaemonId.isNotBlank()
                }
            }
            delay(1_000)
        }

        assertEquals(
            "the authoritative card must replace, not accompany, its optimistic row",
            1,
            manager.state.value.cards.count { it.title == title },
        )
    }
}
