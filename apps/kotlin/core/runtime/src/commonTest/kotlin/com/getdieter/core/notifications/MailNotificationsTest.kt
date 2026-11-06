package com.getdieter.core.notifications

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.MailFolder
import com.getdieter.api.v1.MailHeader
import com.getdieter.api.v1.MailImportance
import com.getdieter.api.v1.MailSender
import com.getdieter.api.v1.MailSenderKind
import com.getdieter.client.v1.MailMessageRef
import com.getdieter.client.v1.MailPreferences
import com.getdieter.core.navigation.Destination
import com.getdieter.core.navigation.OpenTarget
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Mail notifications: only new unread Inbox mail from a machine that was already current notifies,
 * as the device's preferences allow, and reading or filing it elsewhere removes the notification.
 */
class MailNotificationsTest {
    private class RecordingSink : NotificationSink {
        val posted = mutableListOf<NotificationContent>()
        val cancelled = mutableListOf<String>()

        override fun post(content: NotificationContent): Boolean {
            posted += content
            return true
        }

        override fun cancel(key: String) {
            cancelled += key
        }
    }

    private val audit =
        MailHeader(
            id = "ml_audit",
            sender =
                MailSender(
                    kind = MailSenderKind.MAIL_SENDER_KIND_AGENT,
                    card_id = "c_audit",
                    title = "Audit card",
                    schedule_id = "s_audit",
                    schedule_name = "Nightly dependency audit",
                ),
            subject = "Dependency audit — 3 critical, 7 outdated",
            preview = "3 critical advisories need action.",
            importance = MailImportance.MAIL_IMPORTANCE_HIGH,
            folder = MailFolder.MAIL_FOLDER_INBOX,
        )
    private val invoices =
        MailHeader(
            id = "ml_invoices",
            sender =
                MailSender(
                    kind = MailSenderKind.MAIL_SENDER_KIND_AGENT,
                    title = "Migrate invoices",
                ),
            subject = "Invoice migration finished",
            preview = "12,408 rows moved.",
            importance = MailImportance.MAIL_IMPORTANCE_NORMAL,
            folder = MailFolder.MAIL_FOLDER_INBOX,
        )
    private val backup =
        MailHeader(
            id = "ml_backup",
            sender = MailSender(kind = MailSenderKind.MAIL_SENDER_KIND_OPERATOR),
            subject = "Nightly backup completed",
            folder = MailFolder.MAIL_FOLDER_INBOX,
        )

    private fun mail(vararg headers: MailHeader, machine: String = "m_studio") =
        mapOf(machine to headers.associateBy { it.id })

    private val on = MailPreferences(notify = true)

    private fun NotificationPlanner.apply(
        headers: Map<String, Map<String, MailHeader>>,
        settings: NotificationSettings = NotificationSettings(),
        preferences: MailPreferences = on,
        open: Set<MailMessageRef> = emptySet(),
        replaying: (String) -> Boolean = { false },
    ) =
        mail(
            headers,
            headers,
            settings,
            preferences,
            name = { if (it == "m_studio") "Studio" else it },
            open = open,
            replaying = replaying,
        )

    @Test
    fun newUnreadInboxMailFromACurrentMachineNotifiesOnce() {
        val sink = RecordingSink()
        val planner = NotificationPlanner(sink)
        planner.apply(mail(invoices))
        assertTrue(sink.posted.isEmpty(), "the first view only sets the baseline")

        planner.apply(mail(invoices, audit))
        val posted = sink.posted.single()
        assertEquals("mail:m_studio:ml_audit", posted.key)
        assertEquals(NotificationKind.MAIL, posted.kind)
        assertEquals(NotificationRole.RESULTS, posted.role)
        assertEquals("Nightly dependency audit", posted.title)
        assertEquals("Dependency audit — 3 critical, 7 outdated", posted.text)
        assertEquals("3 critical advisories need action.", posted.expanded)
        assertEquals(
            listOf(
                NotificationAction.OPEN,
                NotificationAction.MARK_READ,
                NotificationAction.ARCHIVE,
            ),
            posted.actions,
        )
        assertEquals("Mark as Read", NotificationAction.MARK_READ.title)
        assertEquals("Archive", NotificationAction.ARCHIVE.title)

        planner.apply(mail(invoices, audit))
        assertEquals(1, sink.posted.size, "a message notifies once")

        // Mail that arrives read, outside the Inbox, or on a second machine with a known ID.
        planner.apply(
            mail(
                invoices,
                audit,
                backup.copy(id = "ml_read", read = true),
                backup.copy(id = "ml_archived", folder = MailFolder.MAIL_FOLDER_ARCHIVE),
            ) + mail(audit, machine = "m_office")
        )
        assertEquals(
            listOf("mail:m_studio:ml_audit", "mail:m_office:ml_audit"),
            sink.posted.map { it.key },
            "the same ID on another machine is another message",
        )
        assertEquals(
            "Operator on m_office",
            NotificationContent.mail("m_office", backup, "m_office", NotificationSettings()).title,
        )
    }

    @Test
    fun aMachineCatchingUpNeverNotifiesItsBacklog() {
        val sink = RecordingSink()
        val planner = NotificationPlanner(sink)
        planner.apply(mail(invoices))
        planner.apply(mail(invoices, audit), replaying = { it == "m_studio" })
        assertTrue(sink.posted.isEmpty(), "caught-up mail is not news")
        planner.apply(mail(invoices, audit))
        assertTrue(sink.posted.isEmpty(), "and the baseline moved on")
        planner.apply(mail(invoices, audit, backup))
        assertEquals(listOf("mail:m_studio:ml_backup"), sink.posted.map { it.key })
        assertEquals("Operator on Studio", sink.posted.single().title)

        // After a reset (e.g. another account), the first view is a baseline again.
        planner.reset()
        planner.apply(mail(invoices.copy(id = "ml_new")))
        assertEquals(1, sink.posted.size)
    }

    @Test
    fun preferencesDecideWhatNotifies() {
        val sink = RecordingSink()
        val planner = NotificationPlanner(sink)
        planner.apply(mail())
        planner.apply(mail(invoices), settings = NotificationSettings(enabled = false))
        planner.apply(mail(invoices, audit), preferences = on.copy(notify = false))
        assertTrue(sink.posted.isEmpty(), "notifications or mail notifications are off")
        planner.apply(mail(invoices, audit), preferences = on)
        assertTrue(sink.posted.isEmpty(), "turning them on again replays nothing")

        planner.apply(
            mail(invoices, audit, backup, audit.copy(id = "ml_urgent")),
            preferences = on.copy(notify_important_only = true),
        )
        assertEquals(listOf("mail:m_studio:ml_urgent"), sink.posted.map { it.key })

        // A message open in a reading pane on screen is not notified.
        planner.apply(
            mail(
                invoices,
                audit,
                backup,
                audit.copy(id = "ml_urgent"),
                invoices.copy(id = "ml_open"),
            ),
            open = setOf(MailMessageRef("m_studio", "ml_open")),
        )
        assertEquals(1, sink.posted.size)
    }

    @Test
    fun previewsFollowTheNotificationStyle() {
        fun expanded(settings: NotificationSettings) =
            NotificationContent.mail("m_studio", audit, "Studio", settings).expanded
        assertEquals("3 critical advisories need action.", expanded(NotificationSettings()))
        assertNull(expanded(NotificationSettings(style = NotificationStyle.COMPACT)))
        assertNull(expanded(NotificationSettings(resultPreviews = false)))
        assertNull(
            NotificationContent.mail("m_studio", backup, "Studio", NotificationSettings()).expanded,
            "no preview, no expanded text",
        )
    }

    @Test
    fun readingOrFilingAMessageAnywhereRemovesItsNotification() {
        val sink = RecordingSink()
        val planner = NotificationPlanner(sink)
        planner.apply(mail())
        planner.apply(mail(invoices, audit, backup))
        assertEquals(3, sink.posted.size)

        planner.mailShown(
            mail(
                invoices.copy(read = true),
                audit.copy(folder = MailFolder.MAIL_FOLDER_ARCHIVE),
                backup,
            )
        )
        assertEquals(
            setOf("mail:m_studio:ml_invoices", "mail:m_studio:ml_audit"),
            sink.cancelled.toSet(),
        )
        assertEquals(2, sink.cancelled.size)
        planner.mailShown(mail())
        assertEquals("mail:m_studio:ml_backup", sink.cancelled.last(), "a deleted message too")
        planner.mailShown(mail())
        assertEquals(3, sink.cancelled.size, "each notification is removed once")
    }

    @Test
    fun mailKeysNameTheirMessage() {
        val key = NotificationContent.mailKey("m_studio", "ml_audit")
        assertEquals(MailMessageRef("m_studio", "ml_audit"), NotificationContent.mailRef(key))
        assertEquals(
            MailMessageRef("m:with:colons", "ml_1"),
            NotificationContent.mailRef("mail:m:with:colons:ml_1"),
        )
        assertNull(NotificationContent.mailRef("result:c_1"))
        assertNull(NotificationContent.mailRef("mail:ml_1"))
    }

    // --- Responses -----------------------------------------------------------------------

    private val reviewCard = Card(id = "c_review", board_id = "b", lane = "review")

    private fun route(
        key: String,
        action: String = "",
        target: OpenTarget = OpenTarget.Conversation(reviewCard, Destination.BOARD),
        canFinish: Boolean = true,
    ): NotificationRoute = NotificationResponses.route(key, action, { target }, { canFinish })

    @Test
    fun mailResponsesChangeInPlaceOrOpenTheMessage() {
        val ref = MailMessageRef("m_studio", "ml_audit")
        val key = NotificationContent.mailKey("m_studio", "ml_audit")
        assertEquals(NotificationRoute.ChangeMail(ref, read = true), route(key, "MARK_READ"))
        assertEquals(
            NotificationRoute.ChangeMail(ref, folder = MailFolder.MAIL_FOLDER_ARCHIVE),
            route(key, " archive "),
        )
        assertEquals(NotificationRoute.OpenMail(ref), route(key))
        assertEquals(NotificationRoute.OpenMail(ref), route(key, "OPEN"))
        assertEquals(NotificationRoute.None, route(key, "MARK_DONE"))
    }

    @Test
    fun conversationResponsesOpenWhatTheAccountShows() {
        assertEquals(NotificationRoute.OpenConversation("c_review"), route("result:c_review"))
        assertEquals(
            NotificationRoute.OpenConversation("c_review"),
            route("running:c_review", "OPEN"),
        )
        assertEquals(
            NotificationRoute.OpenConversation("c_late"),
            route("result:c_late", target = OpenTarget.Wait),
            "a conversation that may still arrive opens by ID",
        )
        assertEquals(NotificationRoute.Inbox, route("result:c_gone", target = OpenTarget.Inbox))
        assertEquals(
            NotificationRoute.FinishCard("c_review"),
            route("review:c_review", "MARK_DONE"),
        )
        assertEquals(
            NotificationRoute.OpenConversation("c_review"),
            route("review:c_review", "MARK_DONE", canFinish = false),
            "a card that cannot be finished opens instead",
        )
        assertEquals(
            NotificationRoute.OpenConversation("c_review"),
            route("result:c_review", "MARK_DONE"),
            "only a review is finished",
        )
        assertEquals(NotificationRoute.None, route("result:c_review", "ARCHIVE"))
        assertEquals(NotificationRoute.None, route("connection"))
        assertEquals(NotificationRoute.None, route("result:"))
    }
}
