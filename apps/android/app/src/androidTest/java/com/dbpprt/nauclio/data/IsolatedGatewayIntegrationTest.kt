package com.dbpprt.nauclio.data

import com.dbpprt.nauclio.NauclioApplication
import com.dbpprt.nauclio.connection.ConnectionPhase
import com.dbpprt.nauclio.v1.CreateConversationRequest
import com.dbpprt.nauclio.v1.StartCardRequest
import com.dbpprt.nauclio.v1.SyncFrame
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import kotlin.system.measureTimeMillis

/**
 * Explicitly gated real-emulator coverage for an isolated gateway. It is not
 * part of the normal connected suite because it starts an actual local agent.
 */
@RunWith(AndroidJUnit4::class)
class IsolatedGatewayIntegrationTest {
    @Test
    fun startAdmissionRoundTripsAndPreparesVisibleFixture() = runBlocking {
        val origin = isolatedOrigin()
        val token = argument("isolatedGatewayToken")
        assumeTrue("Pass isolatedGatewayToken to run the isolated gateway test", token.isNotBlank())

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcNauclioRepository(context)
        var transportCardId: String? = null
        try {
            val endpoint = connect(repository, origin, token)
            assertEquals("Gateway relay", repository.prepareDaemon())
            assertEquals("ok", repository.health().status)

            val frames = Channel<SyncFrame>(Channel.UNLIMITED)
            val syncJob = launch { repository.watchSync(conversationLimit = 0).collect(frames::send) }
            val bootstrap = withTimeout(10_000) {
                while (true) {
                    val frame = frames.receive()
                    if (frame.hasSnapshot()) return@withTimeout frame
                }
                error("unreachable")
            }
            assertEquals(0, bootstrap.snapshot.conversationsCount)

            val state = bootstrap.snapshot.state
            val board = state.boardsList.firstOrNull { candidate ->
                candidate.lanesList.any { it.id.equals("todo", ignoreCase = true) } &&
                    candidate.lanesList.any {
                        it.id.equals("running", ignoreCase = true) || it.name.equals("running", ignoreCase = true)
                    }
            } ?: error("The real workspace must have a board with Todo and Running lanes")
            val runningLane = board.lanesList.first {
                it.id.equals("running", ignoreCase = true) || it.name.equals("running", ignoreCase = true)
            }.id
            val harness = repository.harnesses().harnessesList.firstOrNull()
                ?: error("The real daemon must expose at least one harness")
            val nonce = UUID.randomUUID().toString().take(8)
            val transportCard = repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(board.projectId)
                    .setBoardId(board.id)
                    .setLane("todo")
                    .setTitle("Android isolated start transport $nonce")
                    .setPrompt("Automated transport verification. Read only: do not edit files. Reply with E2E_OK.")
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setClientId("android-isolated-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = false,
            )
            transportCardId = transportCard.id

            val createdDelta = withTimeout(10_000) {
                while (true) {
                    val frame = frames.receive()
                    if (frame.hasDelta() && frame.delta.cardsList.any { it.id == transportCard.id }) {
                        return@withTimeout frame
                    }
                }
                error("unreachable")
            }
            assertFalse(createdDelta.hasSnapshot())

            val commandId = UUID.randomUUID().toString()
            val request = StartCardRequest.newBuilder()
                .setCardId(transportCard.id)
                .setClientId("android-isolated-test")
                .setCommandId(commandId)
                .build()
            lateinit var response: com.dbpprt.nauclio.v1.StartCardResponse
            val acknowledgementMillis = measureTimeMillis { response = repository.startCard(request) }
            assertTrue("Start acknowledgement took ${acknowledgementMillis}ms", acknowledgementMillis < 5_000)
            assertTrue(response.accepted)
            assertEquals(commandId, response.commandId)
            assertEquals(runningLane, response.card.lane)
            assertTrue(response.card.initialPromptSentAt.isNotBlank())

            val replay = repository.startCard(request)
            assertTrue(replay.replayed)
            assertEquals(response.card.id, replay.card.id)
            val conversation = withTimeout(10_000) { repository.watchConversation(transportCard.id, 8).first() }
            assertEquals(transportCard.id, conversation.detail.card.id)
            syncJob.cancel()

            runCatching { repository.cancelCard(transportCard.id) }
            repository.archiveCard(transportCard.id, true)
            transportCardId = null

            val fixture = repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(board.projectId)
                    .setBoardId(board.id)
                    .setLane("todo")
                    .setTitle("Android start feedback E2E $nonce")
                    .setPrompt("Visible Android start-feedback verification. Read only: do not edit files. Reply with E2E_UI_OK.")
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setClientId("android-isolated-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = false,
            )

            val application = context.applicationContext as NauclioApplication
            val manager = application.container.connectionManager
            manager.repository.setAccessToken(origin, token)
            manager.updateEndpoints(listOf(origin))
            manager.connect()
            manager.onAppForegrounded(fixture.projectId)
            withTimeout(30_000) {
                manager.state.first { current ->
                    current.phase == ConnectionPhase.CONNECTED && current.cards.any { it.id == fixture.id }
                }
            }
            println(
                "NAUCLIO_UI_FIXTURE card=${fixture.id} project=${fixture.projectId} " +
                    "board=${fixture.boardId} daemon=${endpoint.daemonId}",
            )
        } finally {
            transportCardId?.let { id ->
                runCatching { repository.cancelCard(id) }
                runCatching { repository.archiveCard(id, true) }
            }
            repository.close()
        }
    }

    @Test
    fun archiveVisibleFixtureAndRestoreProductionGateway() = runBlocking {
        val fixtureCardId = argument("fixtureCardId")
        val token = argument("isolatedGatewayToken")
        if (fixtureCardId.isNotBlank() && token.isNotBlank()) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val repository = GrpcNauclioRepository(context)
            try {
                connect(repository, isolatedOrigin(), token)
                repository.prepareDaemon()
                runCatching { repository.cancelCard(fixtureCardId) }
                repository.archiveCard(fixtureCardId, true)
            } finally {
                repository.close()
            }
        }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val application = context.applicationContext as NauclioApplication
        val manager = application.container.connectionManager
        manager.updateEndpoints(NAUCLIO_ENDPOINTS)
        manager.connect()
        delay(1_000)
    }

    private suspend fun connect(
        repository: GrpcNauclioRepository,
        origin: NauclioEndpoint,
        token: String,
    ): NauclioEndpoint {
        repository.setAccessToken(origin, token)
        repository.replaceEndpoints(listOf(origin))
        repository.selectEndpoint(origin)
        val daemon = repository.daemons().daemonsList.single()
        val endpoint = origin.copy(
            id = "${origin.credentialId}#${daemon.id}",
            label = daemon.name.ifBlank { daemon.id },
            daemonId = daemon.id,
        )
        repository.replaceEndpoints(listOf(endpoint))
        repository.selectEndpoint(endpoint)
        return endpoint
    }

    private fun isolatedOrigin(): NauclioEndpoint = NauclioEndpoint(
        id = "isolated_gateway_e2e",
        label = "Isolated Gateway E2E",
        host = argument("isolatedGatewayHost").ifBlank { "10.0.2.2" },
        port = argument("isolatedGatewayPort").toIntOrNull() ?: 14243,
        secure = false,
    )

    private fun argument(name: String): String =
        InstrumentationRegistry.getArguments().getString(name).orEmpty()
}
