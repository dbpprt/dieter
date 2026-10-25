package com.getdieter.core.mail

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.MailFolder
import com.getdieter.api.v1.MailHeader
import com.getdieter.api.v1.MailSender
import com.getdieter.api.v1.MailSenderKind
import com.getdieter.client.v1.MailBox
import com.getdieter.client.v1.MailMessageRef
import com.getdieter.client.v1.MailPreferences
import com.getdieter.core.outbox.Outbox
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.store.WorkspaceStore
import com.getdieter.core.testing.ManualClock
import com.getdieter.core.testing.MemoryDeviceSettings
import com.getdieter.core.testing.offlineSessions
import com.getdieter.core.testing.unreachableChoice
import com.getdieter.core.v1.OutboxKind
import com.getdieter.core.v1.OutboxState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

/**
 * The mailbox without a reachable machine: changes queue in the journaled outbox and show at once,
 * survive a restart, and settle once the machine's headers show them.
 */
class MailboxTest {
    private val clock = ManualClock()
    private val fileSystem = FakeFileSystem()
    private val state = CoreStorage(fileSystem, "/state".toPath())
    private val store = WorkspaceStore(clock)
    private val settings = MemoryDeviceSettings()
    private var headers: Map<String, Map<String, MailHeader>> = emptyMap()
    private var reachable = false

    private fun header(
        id: String,
        folder: MailFolder = MailFolder.MAIL_FOLDER_INBOX,
        read: Boolean = false,
    ) =
        MailHeader(
            id = id,
            sender =
                MailSender(kind = MailSenderKind.MAIL_SENDER_KIND_OPERATOR, label = "backup.sh"),
            subject = "Subject $id",
            sent_at = clock.current.toString(),
            state_changed_at = clock.current.toString(),
            body_digest = "d_$id",
            body_bytes = 10,
            read = read,
            folder = folder,
        )

    private fun outbox(): Outbox =
        Outbox("client", offlineSessions(), store, unreachableChoice(store), clock, SilentLogger) {
                headers
            }
            .also { it.bind(state.scope("outbox")) }

    private class Harness(val outbox: Outbox, val mailbox: Mailbox, val surface: MailSurface)

    private fun harness(outbox: Outbox = outbox()): Harness {
        val projection = {
            MailRules.project(
                MailRules.overlay(headers, outbox.view.value.entries),
                headers.keys.associateWith {
                    MailMachine(
                        it,
                        "Studio",
                        if (reachable) null else "Studio is offline",
                        reachable,
                    )
                },
            )
        }
        val mailbox =
            Mailbox(
                offlineSessions(),
                outbox,
                settings,
                CoroutineScope(Dispatchers.Unconfined),
                SilentLogger,
                projection,
            )
        mailbox.bind(state.scope("mail"))
        return Harness(outbox, mailbox, MailSurface(mailbox, projection))
    }

    private fun Harness.slice() =
        MailRules.slice(
            MailContext(
                mailbox =
                    MailRules.project(
                        MailRules.overlay(headers, outbox.view.value.entries),
                        headers.keys.associateWith {
                            MailMachine(it, "Studio", "Studio is offline", false)
                        },
                    ),
                view = surface.view.value,
                preferences = mailbox.preferences.value,
                body = null,
                liveCards = emptySet(),
                now = clock.now(),
                offset = { 0 },
            )
        )

    @Test
    fun selectingMarksReadAtOnceAndTheChangeWaitsForItsMachine() {
        headers = mapOf("m_studio" to mapOf("ml_1" to header("ml_1"), "ml_2" to header("ml_2")))
        val h = harness()
        assertEquals(2, h.slice().unread)
        h.surface.select(MailMessageRef("m_studio", "ml_1"))
        val entry = h.outbox.view.value.entries.single()
        assertEquals(OutboxKind.OUTBOX_KIND_UPDATE_MAIL, entry.kind)
        assertEquals("m_studio", entry.daemon_id)
        assertTrue(entry.optimistic_id.startsWith(Outbox.MAIL_PREFIX))
        assertEquals(OutboxState.OUTBOX_STATE_QUEUED, entry.state)
        assertEquals(1, h.slice().unread, "the change shows before its machine has it")
        assertTrue(h.slice().reader_!!.read)
        assertEquals(
            1,
            h.outbox.view.value.machines.getValue("m_studio").changeCount,
            "it counts as a queued change of its machine",
        )
        assertTrue(entry.optimistic_id !in h.outbox.view.value.pendingCardIds)

        // Selecting it again, now read, queues nothing more.
        h.surface.select(MailMessageRef("m_studio", "ml_1"))
        assertEquals(1, h.outbox.view.value.entries.size)

        // The journal survives a restart, and the change still shows.
        val restarted = harness(outbox())
        assertEquals(1, restarted.outbox.view.value.entries.size)
        assertEquals(1, restarted.slice().unread)
    }

    @Test
    fun boxActionsQueuePerMachineInBatches() {
        val many = (1..501).associate { "ml_$it" to header("ml_$it") }
        headers =
            mapOf(
                "m_studio" to many,
                "m_office" to
                    mapOf(
                        "ml_t1" to header("ml_t1", MailFolder.MAIL_FOLDER_TRASH),
                        "ml_t2" to header("ml_t2", MailFolder.MAIL_FOLDER_TRASH, read = true),
                    ),
            )
        val h = harness()
        h.surface.markAllRead(
            MailRules.listed(
                    MailRules.project(headers, emptyMap()),
                    h.surface.view.value,
                )
                .filter { !it.header.read }
                .map { it.ref }
        )
        val updates = h.outbox.view.value.entries
        assertEquals(listOf(500, 1), updates.map { MailRules.updateRequest(it)!!.ids.size })
        assertEquals(0, h.slice().unread)

        h.surface.selectBox(MailBox.MAIL_BOX_TRASH)
        assertEquals(2, h.slice().count)
        h.surface.emptyTrash()
        val delete = h.outbox.view.value.entries.last()
        assertEquals(OutboxKind.OUTBOX_KIND_DELETE_MAIL, delete.kind)
        assertEquals("m_office", delete.daemon_id)
        assertEquals(listOf("ml_t1", "ml_t2"), MailRules.deleteRequest(delete)!!.ids.sorted())
        assertEquals(0, h.slice().count, "deleted mail goes at once")
        assertEquals("Trash is empty", h.slice().empty_title)
    }

    @Test
    fun anAcceptedChangeSettlesOnceTheMachineShowsIt() {
        headers = mapOf("m_studio" to mapOf("ml_1" to header("ml_1")))
        val h = harness()
        h.surface.change(
            listOf(MailMessageRef("m_studio", "ml_1")),
            read = null,
            flagged = true,
            folder = MailFolder.MAIL_FOLDER_ARCHIVE,
        )
        val entry = h.outbox.view.value.entries.single()
        // The daemon answers with the state it changed a minute after the header synced.
        clock.current += 1.minutes
        val accepted = entry.copy(server_id = clock.current.toString(), accepted_at_millis = 1)
        val cards = emptyMap<String, Card>()
        val activities = emptyMap<String, Conversation>()
        assertFalse(OutboxPolicy.isSynced(accepted, cards, activities, headers))
        headers =
            mapOf(
                "m_studio" to
                    mapOf(
                        "ml_1" to
                            header("ml_1", MailFolder.MAIL_FOLDER_ARCHIVE).copy(flagged = true)
                    )
            )
        assertTrue(OutboxPolicy.isSynced(accepted, cards, activities, headers))
        h.outbox.reconcile()
        assertEquals(1, h.outbox.view.value.entries.size, "an unaccepted change stays")
    }

    @Test
    fun anUnreachableMachinesBodyIsUnavailableAndPreferencesAreKept() {
        headers = mapOf("m_studio" to mapOf("ml_1" to header("ml_1")))
        val h = harness()
        val item = MailItem("m_studio", header("ml_1"))
        assertEquals(
            MailBody.Unavailable("Studio is offline"),
            h.mailbox.body(item, MailMachine("m_studio", "Studio", "Studio is offline")),
        )
        assertEquals(
            MailBody.Unavailable("Studio is offline"),
            h.mailbox.body(item, MailMachine("m_studio", "Studio")),
        )
        assertEquals(
            MailPreferences(notify = true, notify_important_only = false, app_badge = false),
            h.mailbox.preferences.value,
        )
        h.mailbox.setPreferences(MailPreferences(notify = false, app_badge = true))
        assertEquals("false", settings.values[MailSettings.NOTIFY])
        assertEquals("true", settings.values[MailSettings.APP_BADGE])
        assertEquals(
            MailPreferences(notify = false, app_badge = true),
            harness().mailbox.preferences.value,
        )

        h.surface.setActive(true)
        h.surface.select(MailMessageRef("m_studio", "ml_1"))
        assertEquals(setOf(MailMessageRef("m_studio", "ml_1")), h.mailbox.openRefs())
        h.surface.setActive(false)
        assertTrue(h.mailbox.openRefs().isEmpty(), "a view off screen opens nothing")
        h.surface.reset()
        assertEquals(null, h.surface.view.value.selected)
    }
}
