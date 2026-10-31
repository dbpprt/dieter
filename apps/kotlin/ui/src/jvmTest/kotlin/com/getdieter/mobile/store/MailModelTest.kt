package com.getdieter.mobile.store

import com.getdieter.api.v1.MailFolder
import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class MailModelTest {
    private fun TestScope.store(core: FakeMobileCore) =
        MobileStore(core, StandardTestDispatcher(testScheduler))

    private fun mail(core: FakeMobileCore) = core.sentOf { it.mail }

    private val root = MobileRoute.Mailbox

    @Test
    fun theMailboxIsWatchedForTheBadgeAndActiveOnlyWhileMailIsOpen() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            runCurrent()
            // The badge needs the slice on every tab, so it is observed from the start.
            assertTrue(core.observing(Slice.SLICE_MAIL, MobileStore.MAIL_SCOPE))
            assertTrue(mail(core).isEmpty())
            core.publish(
                Slice.SLICE_MAIL,
                MobileStore.MAIL_SCOPE,
                Update(mail = MailSlice(unread = 4, unread_label = "4")),
            )
            runCurrent()
            assertEquals("4", store.mail.slice.value.unread_label)

            store.openMore(root)
            runCurrent()
            store.selectTab(MobileTab.CHATS)
            runCurrent()
            assertEquals(listOf(true, false), mail(core).mapNotNull { it.active?.on })
            assertTrue(mail(core).all { it.scope == MobileStore.MAIL_SCOPE })
        } finally {
            store.close()
        }
    }

    @Test
    fun anOpenMessageStaysSelectedUntilItsRouteCloses() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            store.openMore(root)
            store.showFrom(root, MobileRoute.MailMessage("d_studio", "ml_audit"))
            runCurrent()
            assertEquals(
                listOf(MailMessageRef(daemon_id = "d_studio", id = "ml_audit")),
                mail(core).mapNotNull { it.select },
            )
            // Its conversation opens above it; the message stays in the reading pane.
            store.openConversation("c_mail_audit")
            runCurrent()
            assertEquals(1, mail(core).mapNotNull { it.select }.size)
            assertIs<MobileRoute.MailMessage>(store.routes.value.stack[2])

            // Another tab keeps the selection; popping back to the list clears it.
            store.selectTab(MobileTab.INBOX)
            store.selectTab(MobileTab.MORE)
            store.popTo(MobileTab.MORE, 3)
            runCurrent()
            assertEquals(1, mail(core).mapNotNull { it.select }.size)
            store.pop()
            runCurrent()
            assertEquals(MailMessageRef(), mail(core).mapNotNull { it.select }.last())
            assertEquals(listOf(MobileRoute.Root(MobileTab.MORE), root), store.routes.value.stack)
        } finally {
            store.close()
        }
    }

    @Test
    fun commandsCarryTheScopeAndTheirReplyFeedsTheSlice() = runTest {
        val reply = MailSlice(box = MailBox.MAIL_BOX_ARCHIVE, unread = 2, unread_label = "2")
        val core = FakeMobileCore { command ->
            if (command.mail != null) Result(mail = reply) else Result(done = Done())
        }
        val store = store(core)
        try {
            val audit = MailMessageRef(daemon_id = "d_studio", id = "ml_audit")
            val backup = MailMessageRef(daemon_id = "d_mini", id = "ml_backup")
            store.mail.change(listOf(audit, backup), folder = MailFolder.MAIL_FOLDER_ARCHIVE)
            store.mail.change(listOf(audit), read = false)
            store.mail.change(emptyList(), flagged = true)
            store.mail.delete(listOf(backup))
            store.mail.selectBox(MailBox.MAIL_BOX_TRASH)
            store.mail.search("audit")
            store.mail.filter(MailFilter(important_only = true))
            store.mail.emptyTrash()
            store.mail.markAllRead()
            runCurrent()
            val sent = mail(core)
            assertTrue(sent.all { it.scope == MobileStore.MAIL_SCOPE })
            val changes = sent.mapNotNull { it.change }
            assertEquals(2, changes.size, "an empty change is not sent")
            assertEquals(listOf(audit, backup), changes[0].refs)
            assertEquals(MailFolder.MAIL_FOLDER_ARCHIVE, changes[0].folder)
            assertNull(changes[0].read)
            assertEquals(false, changes[1].read)
            assertEquals(MailFolder.MAIL_FOLDER_UNSPECIFIED, changes[1].folder)
            assertEquals(listOf(backup), sent.mapNotNull { it.delete }.single().refs)
            assertEquals(MailBox.MAIL_BOX_TRASH, sent.mapNotNull { it.select_box }.single())
            assertEquals("audit", sent.mapNotNull { it.search }.single())
            assertTrue(sent.mapNotNull { it.filter }.single().important_only)
            assertEquals(1, sent.mapNotNull { it.empty_trash }.size)
            assertEquals(1, sent.mapNotNull { it.mark_all_read }.size)
            // The command's reply is the surface after it, which feeds the tab badge.
            assertEquals("2", store.mail.slice.value.unread_label)
        } finally {
            store.close()
        }
    }

    @Test
    fun aWorkspaceLinkOpensTheFileOnTheSendersCheckout() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            store.openMore(root)
            store.showFrom(root, MobileRoute.MailMessage("d_studio", "ml_audit"))
            store.push(
                MobileRoute.FilePath(
                    "README.md",
                    file = true,
                    daemonId = "d_studio",
                    projectId = "p_dieter",
                    checkoutId = "co_main",
                )
            )
            runCurrent()
            val files = core.sentOf { it.files }
            val bind = files.mapNotNull { it.bind }.single()
            assertEquals("d_studio", bind.daemon_id)
            assertEquals("p_dieter", bind.project_id)
            assertEquals("co_main", bind.checkout_id)
            assertEquals("", bind.card_id)
            // The file opens after the bind, on the same scope.
            val bound = files.indexOfFirst { it.bind != null }
            val opened = files.indexOfFirst { it.open_?.path == "README.md" }
            assertTrue(opened > bound, "$files")
            assertTrue(files.all { it.scope == MobileStore.FILES_SCOPE })
        } finally {
            store.close()
        }
    }
}
