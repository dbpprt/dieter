package com.dbpprt.nauclio.connection

import com.dbpprt.nauclio.v1.CreateConversationRequest
import com.dbpprt.nauclio.v1.MessagePart
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConversationOutboxPolicyTest {
    @Test
    fun `starting chat renders its first message while creation is pending`() {
        val request = CreateConversationRequest.newBuilder()
            .setPrompt("  Inspect this screenshot  ")
            .setDeferStart(false)
            .addAttachments(MessagePart.newBuilder().setType("file").setFilename("screen.png"))
            .build()

        val message = optimisticChatMessage(request, "local-initial")

        assertEquals("local-initial", message?.id)
        assertEquals("user", message?.role)
        assertEquals("Inspect this screenshot", message?.partsList?.get(0)?.text)
        assertEquals("screen.png", message?.partsList?.get(1)?.filename)
    }

    @Test
    fun `deferred conversation does not pretend its prompt was sent`() {
        val request = CreateConversationRequest.newBuilder()
            .setPrompt("Keep this as a draft")
            .setDeferStart(true)
            .build()

        assertNull(optimisticChatMessage(request, "local-initial"))
    }

    @Test
    fun `accepted chat replaces its temporary conversation id`() {
        assertEquals("c_server", resolveConversationId("local_chat", mapOf("local_chat" to "c_server")))
        assertEquals("c_existing", resolveConversationId("c_existing", emptyMap()))
        assertNull(resolveConversationId(null, mapOf("local_chat" to "c_server")))
    }
}
