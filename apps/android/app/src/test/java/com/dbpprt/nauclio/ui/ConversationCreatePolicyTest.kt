package com.dbpprt.nauclio.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationCreatePolicyTest {
    @Test
    fun `conversation creation requires a selected project`() {
        assertFalse(
            canCreateConversation(
                projectId = "",
                provider = "codex",
                model = "gpt-5",
                prompt = "Inspect the project",
                chat = true,
                title = "",
            ),
        )
    }

    @Test
    fun `standalone chat can be created for a selected project`() {
        assertTrue(
            canCreateConversation(
                projectId = "project-a",
                provider = "codex",
                model = "gpt-5",
                prompt = "Inspect the project",
                chat = true,
                title = "",
            ),
        )
    }

    @Test
    fun `todo cards stay on the board after creation`() {
        assertFalse(shouldOpenCreatedConversation(chat = false, lane = "todo"))
    }

    @Test
    fun `running cards open after creation`() {
        assertTrue(shouldOpenCreatedConversation(chat = false, lane = "running"))
    }

    @Test
    fun `standalone chats open after creation`() {
        assertTrue(shouldOpenCreatedConversation(chat = true, lane = ""))
    }

    @Test
    fun `standalone chats dispatch their first message immediately`() {
        assertFalse(shouldDeferConversationStart(chat = true, lane = ""))
    }

    @Test
    fun `only non-running board cards defer their first message`() {
        assertTrue(shouldDeferConversationStart(chat = false, lane = "todo"))
        assertFalse(shouldDeferConversationStart(chat = false, lane = "running"))
    }

    @Test
    fun `an attachment can be the initial conversation content`() {
        assertTrue(
            canCreateConversation(
                projectId = "project-a",
                provider = "codex",
                model = "gpt-5",
                prompt = "",
                chat = false,
                title = "Inspect screenshot",
                hasAttachments = true,
            ),
        )
    }
}
