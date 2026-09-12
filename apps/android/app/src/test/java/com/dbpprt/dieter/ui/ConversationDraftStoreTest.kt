package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.HarnessSelection
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.QueuedMessage
import com.google.protobuf.ByteString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationDraftStoreTest {
    @Test
    fun draftsRemainOwnedByTheirConversationAndClearOnlyTheAcceptedRevision() {
        val store = ConversationDraftStore()
        val attachment = filePart("one.txt")
        store.update("card-a") { it.copy(text = "alpha", attachments = listOf(attachment)) }
        store.update("card-b") { it.copy(text = "beta") }

        assertEquals("alpha", store.draft("card-a").text)
        assertEquals("beta", store.draft("card-b").text)

        store.acceptSend("card-a", "older alpha", listOf(attachment))
        assertEquals("alpha", store.draft("card-a").text)
        store.acceptSend("card-a", "alpha", listOf(attachment))
        assertFalse(store.draft("card-a").hasContent)
        assertEquals("beta", store.draft("card-b").text)
    }

    @Test
    fun editingAQueuedMessageRestoresItsContentAttachmentsAndSelection() {
        val store = ConversationDraftStore()
        val existing = filePart("existing.txt")
        store.update("card") {
            it.copy(
                text = "current draft",
                attachments = listOf(existing),
                selection = ConversationComposerSelection("codex", "newer", "high", emptyMap()),
            )
        }
        val queuedAttachment = filePart("queued.txt")
        val queued = QueuedMessage.newBuilder()
            .setId("queue-1")
            .addParts(MessagePart.newBuilder().setType("text").setText("queued text"))
            .addParts(queuedAttachment)
            .setSelection(
                HarnessSelection.newBuilder()
                    .setProvider("codex")
                    .setModel("queued-model")
                    .setEffort("medium")
                    .putProviderOptions("fast_mode", "true"),
            )
            .build()

        assertTrue(store.beginQueueMutation("card", queued.id) != null)
        assertNull(store.beginQueueMutation("card", queued.id))
        assertTrue(store.beginQueueMutation("card", "queue-2") != null)
        val restored = store.finishQueueMutation("card", queued.id, queued, edit = true)

        assertEquals("queued text\n\ncurrent draft", restored.text)
        assertEquals(listOf(queuedAttachment, existing), restored.attachments)
        assertEquals("queued-model", restored.selection?.model)
        assertEquals("true", restored.selection?.providerOptions?.get("fast_mode"))
        assertEquals(setOf("queue-2"), restored.pendingQueueMessageIds)
    }

    @Test
    fun optimisticConversationIdRetargetKeepsTheDraft() {
        val store = ConversationDraftStore()
        store.update("local:1") { it.copy(text = "survives admission") }
        store.retarget("local:1", "card-1")

        assertFalse(store.draft("local:1").hasContent)
        assertEquals("survives admission", store.draft("card-1").text)
    }

    private fun filePart(name: String): MessagePart = MessagePart.newBuilder()
        .setType("file")
        .setFilename(name)
        .setMediaType("text/plain")
        .setData(ByteString.copyFromUtf8(name))
        .build()
}
