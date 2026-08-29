package com.dbpprt.dieter.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.SyncFrame
import kotlinx.coroutines.channels.Channel
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

/**
 * Explicitly gated end-to-end coverage for background transcript sync against
 * an isolated local gateway copy (scripts/isolated-gateway). Run with
 * `adb reverse tcp:14243 tcp:14243` so device loopback reaches the host.
 */
@RunWith(AndroidJUnit4::class)
class BackgroundTranscriptSyncIntegrationTest {
    @Test
    fun transcriptsArriveThroughGlobalSyncWithoutOpeningTheChat() = runBlocking {
        val token = argument("isolatedGatewayToken")
        assumeTrue("Pass isolatedGatewayToken to run the isolated gateway test", token.isNotBlank())
        val origin = isolatedOrigin()

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcDieterRepository(context)
        var chatId: String? = null
        try {
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
            assertEquals("Gateway relay", repository.prepareDaemon())

            val project = repository.state().projectsList.single()
            val chat = repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(project.id)
                    .setTitle("Background sync E2E ${UUID.randomUUID().toString().take(8)}")
                    .setPrompt("Reply with BG_SYNC_OK.")
                    .setProvider("mock")
                    .setModel("mock")
                    .setDeferStart(true)
                    .setWorkspaceMode("project")
                    .setClientId("android-bg-sync-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = true,
            )
            chatId = chat.id

            val frames = Channel<SyncFrame>(Channel.UNLIMITED)
            val syncJob = launch {
                repository.watchSync(conversationLimit = 30, recentConversationLimit = 8).collect(frames::send)
            }
            val bootstrap = withTimeout(10_000) {
                while (true) {
                    val frame = frames.receive()
                    if (frame.hasSnapshot()) return@withTimeout frame
                }
                @Suppress("UNREACHABLE_CODE")
                error("unreachable")
            }
            assertTrue(
                "Bootstrap snapshot must carry the recent chat transcript",
                bootstrap.snapshot.conversationsList.any { it.detail.card.id == chat.id },
            )

            val messageId = "msg_bg_sync_${UUID.randomUUID().toString().replace("-", "").take(12)}"
            repository.sendMessage(
                SendMessageRequest.newBuilder()
                    .setCardId(chat.id)
                    .addParts(MessagePart.newBuilder().setType("text").setText("Background delta please"))
                    .setProvider("mock")
                    .setModel("mock")
                    .setClientId("android-bg-sync-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .setMessageId(messageId)
                    .build(),
            )
            withTimeout(15_000) {
                while (true) {
                    val frame = frames.receive()
                    assertFalse("Live frames must stay deltas", frame.hasSnapshot() && !frame.reset)
                    val arrived = frame.delta.conversationsList.any { conversation ->
                        conversation.detail.card.id == chat.id &&
                            conversation.conversation.messagesList.any { it.id == messageId }
                    }
                    if (arrived) return@withTimeout
                }
            }
            syncJob.cancel()
        } finally {
            chatId?.let { id ->
                runCatching { repository.cancelCard(id) }
                runCatching { repository.archiveCard(id, true) }
            }
            repository.close()
        }
    }

    @Test
    fun connectionManagerKeepsTranscriptsWarmInBackground() = runBlocking {
        val token = argument("isolatedGatewayToken")
        assumeTrue("Pass isolatedGatewayToken to run the isolated gateway test", token.isNotBlank())
        val origin = isolatedOrigin()

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val application = context.applicationContext as DieterApplication
        val manager = application.container.connectionManager
        val fixture = GrpcDieterRepository(context)
        var chatId: String? = null
        try {
            fixture.setAccessToken(origin, token)
            fixture.replaceEndpoints(listOf(origin))
            fixture.selectEndpoint(origin)
            val daemon = fixture.daemons().daemonsList.single()
            val routed = origin.copy(
                id = "${origin.credentialId}#${daemon.id}",
                label = daemon.name.ifBlank { daemon.id },
                daemonId = daemon.id,
            )
            fixture.replaceEndpoints(listOf(routed))
            fixture.selectEndpoint(routed)
            fixture.prepareDaemon()
            val project = fixture.state().projectsList.single()
            val chat = fixture.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(project.id)
                    .setTitle("Warm cache E2E ${UUID.randomUUID().toString().take(8)}")
                    .setPrompt("Reply with WARM_OK.")
                    .setProvider("mock")
                    .setModel("mock")
                    .setWorkspaceMode("project")
                    .setClientId("android-bg-sync-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = true,
            )
            chatId = chat.id

            manager.repository.setAccessToken(origin, token)
            manager.updateEndpoints(listOf(origin))
            manager.connect()
            manager.onAppForegrounded(project.id)
            val warmed = withTimeout(30_000) {
                manager.state.first { state ->
                    state.phase == ConnectionPhase.CONNECTED &&
                        (state.activeConversations[chat.id]?.conversation?.messagesCount ?: 0) > 0
                }
            }
            val transcript = warmed.activeConversations.getValue(chat.id)
            assertTrue(
                "Warm transcript must contain the initial prompt turn",
                transcript.conversation.messagesList.isNotEmpty(),
            )
        } finally {
            chatId?.let { id ->
                runCatching { fixture.cancelCard(id) }
                runCatching { fixture.archiveCard(id, true) }
            }
            fixture.close()
            runCatching {
                manager.updateEndpoints(DIETER_ENDPOINTS)
                manager.disconnect()
            }
        }
    }

    private fun isolatedOrigin(): DieterEndpoint = DieterEndpoint(
        id = "isolated_gateway_bg_sync",
        label = "Isolated Gateway BG Sync",
        host = argument("isolatedGatewayHost").ifBlank { "127.0.0.1" },
        port = argument("isolatedGatewayPort").toIntOrNull() ?: 14243,
        secure = false,
    )

    private fun argument(name: String): String =
        InstrumentationRegistry.getArguments().getString(name).orEmpty()
}
