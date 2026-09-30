package com.dbpprt.dieter.connection

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.e2e.IsolatedCore
import java.util.UUID
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okio.ByteString.Companion.encodeUtf8
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Android outbox -> isolated gateway/daemon -> authoritative sync coverage. */
@RunWith(AndroidJUnit4::class)
class ConversationCreationOutboxEndToEndTest {
    @Test
    fun acceptedCardReplacesItsOptimisticRow() {
        val token = InstrumentationRegistry.getArguments().getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val container = (InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as DieterApplication).container
        val core = container.core
        val connected = IsolatedCore.connect(container)
        val harness = IsolatedCore.harnesses(container, IsolatedCore.daemonId(container)).first { it.models.isNotEmpty() }
        val model = harness.models.first()
        val board = connected.boards.values.flatten().first()
        val project = connected.projects.first { it.id == board.project_id }
        val title = "One Android card ${UUID.randomUUID().toString().take(8)}"
        fun count() = core.workspace.state.value.allItems.count { it.title == title }

        var cardId: String? = null
        try {
            runBlocking {
                val attachment = MessagePart(type = "file", filename = "queued.txt", media_type = "text/plain", data_ = "Exact queued attachment bytes".encodeUtf8())
                val request = CreateConversationRequest(
                    checkout_id = requireNotNull(project.checkouts.firstOrNull()).id, project_id = project.id, board_id = board.id,
                    lane = board.lanes.first().id, title = title, prompt = title, provider = harness.id, model = model.id,
                    workspace_mode = "project", defer_start = true, attachments = listOf(attachment),
                )
                val submission = UUID.randomUUID().toString()
                core.setConnected(false)
                withTimeout(30.seconds) { core.connection.state.first { it.phase == ConnectionPhase.DISCONNECTED } }
                core.createConversation(request, chat = false, submissionId = submission)
                core.createConversation(request, chat = false, submissionId = submission)
                assertEquals(1, count())

                IsolatedCore.connect(container)
                val card = withTimeout(30.seconds) {
                    core.workspace.state.first { view -> view.allItems.singleOrNull { it.title == title }?.owner_daemon_id?.isNotBlank() == true }
                }.allItems.single { it.title == title }
                cardId = card.id
                // Replaying after receipt/optimistic cleanup still targets the original task.
                core.createConversation(request, chat = false, submissionId = submission)
                delay(1_000)
                assertEquals(card.id, core.workspace.state.value.allItems.single { it.title == title }.id)
                assertEquals(listOf(attachment), IsolatedCore.conversation(container, card.id).conversation?.draft_attachments)
            }

            assertEquals("the authoritative card must replace, not accompany, its optimistic row", 1, count())
        } finally {
            runBlocking { cardId?.let { id -> runCatching { core.onBoard { archive(id) } } } }
            IsolatedCore.disconnect(container)
        }
    }
}
