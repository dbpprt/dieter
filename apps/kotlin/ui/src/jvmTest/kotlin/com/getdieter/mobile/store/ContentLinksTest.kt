package com.getdieter.mobile.store

import com.getdieter.api.v1.*
import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription
import com.getdieter.mobile.navigation.*
import kotlin.test.*
import kotlinx.coroutines.*

class ContentLinksTest {
    @Test
    fun conversationFilesUseTheOwningWorktreeAndWebLinksUseTheBrowser() =
        runBlocking<Unit> {
            val commands = mutableListOf<Command>()
            val core =
                object : MobileCore {
                    override suspend fun dispatch(command: Command): Result {
                        commands += command
                        return if (command.admin?.conversation_workspace != null)
                            Result(workspace = Workspace(path = "/owner/worktree"))
                        else Result(done = Done())
                    }

                    override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
                        ClientSubscription {}
                }
            val store = MobileStore(core, Dispatchers.Unconfined)
            try {
                store.openConversation("card")
                store.conversation.slice.value =
                    ConversationSlice(
                        card_id = "card",
                        daemon_id = "owner",
                        card = Card(id = "card", project_id = "project"),
                    )
                val web = mutableListOf<String>()
                store.openContentLink("https://example.com/a_(b)", web::add, "card")
                assertEquals(listOf("https://example.com/a_(b)"), web)
                assertTrue(commands.none { it.admin?.conversation_workspace != null })
                store.openContentLink("/owner/worktree/images/chart%20(2).png", web::add, "card")
                assertEquals(
                    MobileRoute.FilePath("images/chart (2).png", true, "card"),
                    store.routes.value.top,
                )
                val binding = commands.last { it.files?.bind != null }.files!!.bind!!
                assertEquals("owner", binding.daemon_id)
                assertEquals("card", binding.card_id)
                assertEquals(
                    "images/chart (2).png",
                    commands.last { it.files?.open_ != null }.files!!.open_!!.path,
                )
                store.openContentLink("../notes.md:12", web::add, "card", "images/readme.md")
                assertEquals(MobileRoute.FilePath("notes.md", true, "card"), store.routes.value.top)
                store.openContentLink("/owner/private.png", web::add, "card")
                assertEquals(
                    "This file is outside the conversation's workspace.",
                    store.error.value,
                )
                assertEquals(MobileRoute.FilePath("notes.md", true, "card"), store.routes.value.top)
            } finally {
                store.close()
            }
        }

    @Test
    fun lateWorkspaceResolutionDoesNotNavigateAfterLeavingConversation() =
        runBlocking<Unit> {
            val waiting = CompletableDeferred<Result>()
            val core =
                object : MobileCore {
                    override suspend fun dispatch(command: Command): Result =
                        if (command.admin?.conversation_workspace != null) waiting.await()
                        else Result(done = Done())

                    override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
                        ClientSubscription {}
                }
            val store = MobileStore(core, Dispatchers.Unconfined)
            try {
                store.openConversation("card")
                store.conversation.slice.value =
                    ConversationSlice(
                        card_id = "card",
                        daemon_id = "owner",
                        card = Card(id = "card"),
                    )
                store.openContentLink("image.png", {}, "card")
                store.pop()
                waiting.complete(Result(workspace = Workspace(path = "/owner/worktree")))
                assertIs<MobileRoute.Root>(store.routes.value.top)
            } finally {
                store.close()
            }
        }
}
