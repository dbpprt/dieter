package com.getdieter.core.mail

import com.getdieter.api.v1.DeleteMailRequest
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.MailFolder
import com.getdieter.api.v1.MailHeader
import com.getdieter.api.v1.MailImportance
import com.getdieter.api.v1.MailSender
import com.getdieter.api.v1.MailSenderKind
import com.getdieter.api.v1.UpdateMailRequest
import com.getdieter.client.v1.MailBox
import com.getdieter.client.v1.MailFilter
import com.getdieter.client.v1.MailMessageRef
import com.getdieter.client.v1.MailPreferences
import com.getdieter.client.v1.MailSenderStyle
import com.getdieter.core.runtime.localUtcOffsetSeconds
import com.getdieter.core.testing.MemoryDeviceSettings
import com.getdieter.core.v1.OutboxEntry
import com.getdieter.core.v1.OutboxKind
import com.getdieter.core.v1.OutboxState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Instant
import okio.ByteString.Companion.toByteString

class MailRulesTest {
    /** Sunday 25 October 2026, 10:00 UTC. */
    private val now = Instant.parse("2026-10-25T10:00:00Z")
    private val utc: (Instant) -> Int = { 0 }
    private val berlin: (Instant) -> Int = { 2 * 3_600 }
    private val pacific: (Instant) -> Int = { -7 * 3_600 }

    private val schedule =
        MailSender(
            kind = MailSenderKind.MAIL_SENDER_KIND_AGENT,
            card_id = "c_audit",
            scope = "card",
            title = "Nightly dependency audit",
            project_id = "p_e2e",
            project_name = "Isolated E2E",
            checkout_id = "co_1",
            schedule_id = "s_audit",
            schedule_name = "Nightly dependency audit",
            harness = "claude-code",
            model = "sonnet",
        )
    private val card =
        MailSender(
            kind = MailSenderKind.MAIL_SENDER_KIND_AGENT,
            card_id = "c_invoices",
            scope = "card",
            title = "Migrate invoices",
            project_id = "p_e2e",
            project_name = "Isolated E2E",
            checkout_id = "co_1",
            harness = "codex",
            model = "gpt-6-astra",
        )
    private val chat = card.copy(card_id = "c_chat", scope = "chat", title = "Pricing chat")
    private val operator =
        MailSender(kind = MailSenderKind.MAIL_SENDER_KIND_OPERATOR, label = "backup.sh")

    private val catalog =
        listOf(
            Harness(
                id = "claude-code",
                name = "Claude Code",
                models =
                    listOf(
                        HarnessModel(id = "sonnet", name = "Sonnet"),
                        HarnessModel(id = "claude-sonnet-4-5", name = "Claude Sonnet 4.5"),
                    ),
            ),
            Harness(
                id = "codex",
                name = "Codex",
                models = listOf(HarnessModel(id = "gpt-6-astra", name = "GPT-6 Astra")),
            ),
        )

    private fun header(
        id: String,
        sender: MailSender = card,
        sent: Instant = now - 1.hours,
        read: Boolean = false,
        flagged: Boolean = false,
        folder: MailFolder = MailFolder.MAIL_FOLDER_INBOX,
        important: Boolean = false,
        subject: String = "Subject $id",
        preview: String = "Preview of $id",
    ) =
        MailHeader(
            id = id,
            sender = sender,
            subject = subject,
            preview = preview,
            importance =
                if (important) MailImportance.MAIL_IMPORTANCE_HIGH
                else MailImportance.MAIL_IMPORTANCE_NORMAL,
            sent_at = sent.toString(),
            body_digest = "d_$id",
            body_bytes = 100,
            read = read,
            flagged = flagged,
            folder = folder,
            state_changed_at = sent.toString(),
        )

    private val machines =
        mapOf(
            "m_studio" to MailMachine("m_studio", "Studio", reachable = true),
            "m_office" to MailMachine("m_office", "mbp-office", "mbp-office is offline"),
        )

    private fun mailbox(vararg items: Pair<String, MailHeader>) =
        MailRules.project(
            items.groupBy({ it.first }, { it.second }).mapValues { (_, headers) ->
                headers.associateBy { it.id }
            },
            machines,
        )

    private fun context(
        mailbox: MailProjection,
        view: MailView = MailView(),
        body: MailBody? = null,
        liveCards: Set<String> = emptySet(),
        preferences: MailPreferences = MailSettings.load(MemoryDeviceSettings()),
        loading: Boolean = false,
        offset: (Instant) -> Int = utc,
    ) =
        MailContext(
            mailbox = mailbox,
            view = view,
            preferences = preferences,
            body = body,
            liveCards = liveCards,
            now = now,
            offset = offset,
            harnesses = { catalog },
            loading = loading,
        )

    // --- Dates -------------------------------------------------------------------------

    @Test
    fun theDevicesZoneIsAWholeOffsetFromUtc() {
        val offset = localUtcOffsetSeconds(now)
        assertTrue(offset in -14 * 3_600..14 * 3_600, "$offset")
        assertEquals(0, offset % 900, "zones are whole quarter hours")
    }

    @Test
    fun theCalendarMatchesKnownDays() {
        val day = LocalDay.of(now, 0)
        assertEquals(Triple(2026, 10, 25), Triple(day.year, day.month, day.day))
        assertEquals(7, day.weekday, "25 October 2026 is a Sunday")
        assertEquals(LocalDay.of(Instant.parse("2026-10-19T00:00:00Z"), 0).epochDay, day.weekStart)
        val leap = LocalDay.of(Instant.parse("2024-02-29T23:59:59Z"), 0)
        assertEquals(Triple(2024, 2, 29), Triple(leap.year, leap.month, leap.day))
        val early = LocalDay.of(Instant.parse("1969-12-31T23:00:00Z"), 0)
        assertEquals(Triple(1969, 12, 31), Triple(early.year, early.month, early.day))
        assertEquals(3, early.weekday, "the last day of 1969 was a Wednesday")
    }

    @Test
    fun sectionsAreTodayYesterdayThisWeekLastWeekThenMonths() {
        fun section(at: String, offset: (Instant) -> Int = utc) =
            MailRules.section(Instant.parse(at), now, offset)
        assertEquals("today" to "Today", section("2026-10-25T00:00:00Z"))
        assertEquals("today" to "Today", section("2026-10-25T11:00:00Z"), "a clock ahead is today")
        assertEquals("yesterday" to "Yesterday", section("2026-10-24T23:59:00Z"))
        assertEquals("this-week" to "This week", section("2026-10-19T00:00:00Z"), "Monday")
        assertEquals("last-week" to "Last week", section("2026-10-18T23:59:00Z"))
        assertEquals("last-week" to "Last week", section("2026-10-12T00:00:00Z"))
        assertEquals("2026-10" to "October 2026", section("2026-10-11T12:00:00Z"))
        assertEquals("2026-09" to "September 2026", section("2026-09-30T12:00:00Z"))
        assertEquals("2025-12" to "December 2025", section("2025-12-31T12:00:00Z"))
        assertEquals("earlier" to "Earlier", MailRules.section(null, now, utc))
    }

    @Test
    fun daysAreTheDeviceZonesAcrossBoundaries() {
        val late = Instant.parse("2026-10-24T23:30:00Z")
        assertEquals("yesterday", MailRules.section(late, now, utc).first)
        assertEquals("today", MailRules.section(late, now, berlin).first, "01:30 in Berlin")
        assertEquals("yesterday", MailRules.section(late, now, pacific).first)
        assertEquals("01:30", MailRules.timeLabel(late, now, berlin))
        assertEquals("Sat", MailRules.timeLabel(late, now, utc))
        assertEquals("Yesterday 16:30", MailRules.sentLabel(late, now, pacific))
        // Just after midnight in Berlin: ten minutes ago was yesterday there, today in UTC.
        val midnight = Instant.parse("2026-10-24T22:10:00Z")
        val before = Instant.parse("2026-10-24T21:50:00Z")
        assertEquals("Yesterday 23:50", MailRules.sentLabel(before, midnight, berlin))
        assertEquals("Today 21:50", MailRules.sentLabel(before, midnight, utc))
        // Weeks start on the device zone's Monday: 03:00 UTC on Monday is Sunday evening in
        // Pacific.
        val saturday = Instant.parse("2026-10-24T12:00:00Z")
        val early = Instant.parse("2026-10-19T03:00:00Z")
        assertEquals("this-week", MailRules.section(early, saturday, utc).first)
        assertEquals("last-week", MailRules.section(early, saturday, pacific).first)
        assertEquals("Mon", MailRules.timeLabel(early, saturday, utc))
        assertEquals("Sun", MailRules.timeLabel(early, saturday, pacific))
    }

    @Test
    fun timeAndSentLabelsShortenWithAge() {
        fun time(at: String) = MailRules.timeLabel(Instant.parse(at), now, utc)
        assertEquals("09:14", time("2026-10-25T09:14:00Z"))
        assertEquals("Sat", time("2026-10-24T22:10:00Z"))
        assertEquals("Mon", time("2026-10-19T08:00:00Z"), "six days ago")
        assertEquals("18 Oct", time("2026-10-18T08:00:00Z"), "a week ago")
        assertEquals("12 Oct", time("2026-10-12T08:00:00Z"))
        assertEquals("12 Oct 2025", time("2025-10-12T08:00:00Z"))
        assertEquals("", MailRules.timeLabel(null, now, utc))

        fun sent(at: String, at2: Instant = now) = MailRules.sentLabel(Instant.parse(at), at2, utc)
        assertEquals("Today 09:14", sent("2026-10-25T09:14:00Z"))
        assertEquals("Yesterday 22:10", sent("2026-10-24T22:10:00Z"))
        assertEquals(
            "Sun 25 Oct 2026, 09:14",
            sent("2026-10-25T09:14:00Z", Instant.parse("2026-11-02T10:00:00Z")),
        )
    }

    // --- Boxes and counts --------------------------------------------------------------

    @Test
    fun boxesCountTheirMailAndTheBadgeCountsUnreadInboxMailEverywhere() {
        val mailbox =
            mailbox(
                "m_studio" to header("ml_1"),
                "m_studio" to header("ml_2", read = true, flagged = true),
                "m_office" to
                    header("ml_3", flagged = true, folder = MailFolder.MAIL_FOLDER_ARCHIVE),
                "m_office" to header("ml_4", folder = MailFolder.MAIL_FOLDER_TRASH, flagged = true),
                "m_office" to header("ml_5", folder = MailFolder.MAIL_FOLDER_UNSPECIFIED),
            )
        val rows = MailRules.boxes(mailbox.items, MailBox.MAIL_BOX_FLAGGED).associateBy { it.box }
        assertEquals(MailRules.BOXES, rows.keys.toList())
        assertEquals(3, rows.getValue(MailBox.MAIL_BOX_INBOX).total, "an unset folder is the Inbox")
        assertEquals("2", rows.getValue(MailBox.MAIL_BOX_INBOX).count_label)
        assertEquals(2, rows.getValue(MailBox.MAIL_BOX_FLAGGED).total, "Flagged leaves out Trash")
        assertEquals("2", rows.getValue(MailBox.MAIL_BOX_FLAGGED).count_label)
        assertTrue(rows.getValue(MailBox.MAIL_BOX_FLAGGED).selected)
        assertEquals(2, rows.getValue(MailBox.MAIL_BOX_UNREAD).total)
        assertEquals("1", rows.getValue(MailBox.MAIL_BOX_ARCHIVE).count_label)
        assertEquals("1", rows.getValue(MailBox.MAIL_BOX_TRASH).count_label, "Trash counts all")
        assertEquals(2, MailRules.unread(mailbox.items))

        val slice =
            MailRules.slice(
                context(mailbox, preferences = MailPreferences(notify = true, app_badge = true))
            )
        assertEquals(2, slice.unread)
        assertEquals("2", slice.unread_label)
        assertEquals("2", slice.app_badge)
        assertEquals("", MailRules.slice(context(mailbox)).app_badge, "the badge is off by default")

        val many =
            MailRules.project(
                mapOf("m_studio" to (1..120).associate { "ml_$it" to header("ml_$it") }),
                machines,
            )
        assertEquals("99+", MailRules.slice(context(many)).unread_label)
        assertEquals("", MailRules.slice(context(mailbox(), loading = false)).unread_label)
    }

    @Test
    fun theListIsNewestFirstInDateGroupsWithRenderedRows() {
        val mailbox =
            mailbox(
                "m_studio" to
                    header(
                        "ml_a",
                        schedule,
                        Instant.parse("2026-10-25T09:14:00Z"),
                        important = true,
                        subject = "Dependency audit — 3 critical, 7 outdated",
                    ),
                "m_studio" to header("ml_b", card, Instant.parse("2026-10-25T08:02:00Z")),
                "m_office" to
                    header("ml_c", chat, Instant.parse("2026-10-24T18:00:00Z"), read = true),
                "m_office" to header("ml_d", operator, Instant.parse("2026-09-03T18:00:00Z")),
                "m_studio" to header("ml_e", card, Instant.parse("2026-10-25T08:02:00Z")),
            )
        val slice =
            MailRules.slice(
                context(mailbox, MailView(selected = MailMessageRef("m_studio", "ml_b")))
            )
        assertEquals(listOf("today", "yesterday", "2026-09"), slice.sections.map { it.id })
        assertEquals(
            listOf("ml_a", "ml_e", "ml_b"),
            slice.sections[0].rows.map { it.ref!!.id },
            "ties go by ID, newest first",
        )
        assertEquals(5, slice.count)
        val audit = slice.sections[0].rows[0]
        assertEquals("Nightly dependency audit", audit.sender)
        assertEquals("Isolated E2E · Studio · Claude Code", audit.sender_detail)
        assertEquals(MailSenderStyle.MAIL_SENDER_STYLE_SCHEDULE, audit.sender_style)
        assertEquals("claude-code", audit.harness)
        assertEquals("ND", audit.initials)
        assertEquals("schedule:s_audit", audit.sender_key)
        assertEquals("09:14", audit.time_label)
        assertTrue(audit.important)
        assertEquals(MailFolder.MAIL_FOLDER_INBOX, audit.folder)
        assertEquals(
            "Unread, important. Nightly dependency audit: Dependency audit — 3 critical, 7 outdated, 09:14",
            audit.accessibility_label,
        )
        assertTrue(slice.sections[0].rows.single { it.ref!!.id == "ml_b" }.selected)
        val pricing = slice.sections[1].rows.single()
        assertEquals(MailSenderStyle.MAIL_SENDER_STYLE_CHAT, pricing.sender_style)
        assertEquals("mbp-office is offline", pricing.stale)
        assertEquals(
            "Pricing chat: Subject ml_c, Sat. mbp-office is offline",
            pricing.accessibility_label,
        )
        val backup = slice.sections[2].rows.single()
        assertEquals("backup.sh", backup.sender)
        assertEquals("mbp-office", backup.sender_detail)
        assertEquals(MailSenderStyle.MAIL_SENDER_STYLE_OPERATOR, backup.sender_style)
        assertEquals("", backup.harness)
        assertEquals("operator:backup.sh", backup.sender_key)
        assertEquals("3 Sep", backup.time_label)
        assertEquals("", slice.empty_title)
    }

    @Test
    fun sendersAreNamedByScheduleConversationLabelOrMachine() {
        assertEquals("Nightly dependency audit", MailRules.sender(schedule, "Studio"))
        assertEquals("Migrate invoices", MailRules.sender(card, "Studio"))
        assertEquals("backup.sh", MailRules.sender(operator, "Studio"))
        assertEquals(
            "Operator on Studio",
            MailRules.sender(operator.copy(label = "", device_id = "dev_1"), "Studio"),
        )
        assertEquals("Agent on Studio", MailRules.sender(card.copy(title = ""), "Studio"))
        assertEquals("card:c_invoices", MailRules.senderKey(card, "m_studio"))
        assertEquals("card:c_chat", MailRules.senderKey(chat, "m_studio"))
        assertEquals(
            "operator:dev_1",
            MailRules.senderKey(operator.copy(label = "", device_id = "dev_1"), "m_studio"),
        )
        assertEquals(
            "operator:m_studio",
            MailRules.senderKey(operator.copy(label = ""), "m_studio"),
        )
        assertEquals(MailSenderStyle.MAIL_SENDER_STYLE_CARD, MailRules.style(card))
        assertEquals("Claude Code Sonnet", MailRules.agentLabel("claude-code", "sonnet", catalog))
        assertEquals(
            "Claude Sonnet 4.5",
            MailRules.agentLabel("claude-code", "claude-sonnet-4-5", catalog),
            "a model that names its maker stands alone",
        )
        assertEquals("Codex GPT-6 Astra", MailRules.agentLabel("codex", "gpt-6-astra", catalog))
        assertEquals("pi luna", MailRules.agentLabel("pi", "luna", catalog), "an unknown catalog")
        assertEquals("Codex", MailRules.agentLabel("codex", "", catalog))
    }

    // --- Search, filters, empty states -------------------------------------------------

    @Test
    fun searchAndFiltersNarrowTheShownBoxAndOptionsComeFromIt() {
        val mailbox =
            mailbox(
                "m_studio" to
                    header("ml_1", schedule, subject = "Dependency audit", important = true),
                "m_studio" to header("ml_2", card, preview = "Totals match to the cent"),
                "m_office" to header("ml_3", operator.copy(project_name = ""), subject = "Backup"),
                "m_office" to
                    header(
                        "ml_4",
                        card.copy(project_id = "p_other", project_name = "Atlas"),
                        folder = MailFolder.MAIL_FOLDER_ARCHIVE,
                    ),
            )
        fun listed(view: MailView) = MailRules.listed(mailbox, view).map { it.header.id }
        assertEquals(listOf("ml_2"), listed(MailView(search = "CENT")), "the preview, any case")
        assertEquals(listOf("ml_1"), listed(MailView(search = " nightly ")), "the sender")
        assertEquals(
            listOf("ml_2", "ml_1").sorted(),
            listed(MailView(search = "isolated")).sorted(),
        )
        assertEquals(listOf("ml_3"), listed(MailView(filter = MailFilter(daemon_id = "m_office"))))
        assertEquals(
            listOf("ml_1"),
            listed(MailView(filter = MailFilter(sender_key = "schedule:s_audit"))),
        )
        assertEquals(listOf("ml_1"), listed(MailView(filter = MailFilter(important_only = true))))
        assertEquals(
            listOf("ml_4"),
            listed(
                MailView(
                    box = MailBox.MAIL_BOX_ARCHIVE,
                    filter = MailFilter(project_id = "p_other"),
                )
            ),
        )

        val slice =
            MailRules.slice(context(mailbox, MailView(filter = MailFilter(project_id = "p_e2e"))))
        assertEquals(listOf("p_e2e"), slice.projects.map { it.id }, "only the shown box's projects")
        assertTrue(slice.projects.single().selected)
        assertEquals(listOf("mbp-office", "Studio"), slice.machines.map { it.title })
        assertEquals(
            listOf("backup.sh", "Migrate invoices", "Nightly dependency audit"),
            slice.senders.map { it.title },
        )
        assertEquals(2, slice.count)
    }

    @Test
    fun emptyListsSayWhy() {
        val none = MailRules.slice(context(mailbox()))
        assertEquals(MailRules.NO_MAIL_TITLE, none.empty_title)
        assertEquals(
            "Agents in cards, chats and schedules created with Mail access send their reports here.",
            none.empty_detail,
        )
        assertEquals("", MailRules.slice(context(mailbox(), loading = true)).empty_title)
        assertTrue(MailRules.slice(context(mailbox(), loading = true)).loading)
        val archived =
            mailbox("m_studio" to header("ml_1", folder = MailFolder.MAIL_FOLDER_ARCHIVE))
        assertEquals("Inbox is empty", MailRules.slice(context(archived)).empty_title)
        fun empty(box: MailBox) = MailRules.slice(context(archived, MailView(box = box)))
        assertEquals("No flagged mail", empty(MailBox.MAIL_BOX_FLAGGED).empty_title)
        assertEquals("No unread mail", empty(MailBox.MAIL_BOX_UNREAD).empty_title)
        assertEquals("Trash is empty", empty(MailBox.MAIL_BOX_TRASH).empty_title)
        assertEquals(
            "Deleted mail stays here for 30 days.",
            empty(MailBox.MAIL_BOX_TRASH).empty_detail,
        )
        assertEquals("", empty(MailBox.MAIL_BOX_ARCHIVE).empty_title)
        val miss =
            MailRules.slice(
                context(archived, MailView(box = MailBox.MAIL_BOX_ARCHIVE, search = "zebra"))
            )
        assertEquals("No results", miss.empty_title)
        assertEquals("Nothing matches “zebra”.", miss.empty_detail)
    }

    // --- The reading pane --------------------------------------------------------------

    @Test
    fun theReaderShowsTheBodyAndWhetherTheConversationOpens() {
        val audit =
            header("ml_a", schedule, Instant.parse("2026-10-25T09:14:00Z"), important = true)
        val smoke =
            header("ml_s", schedule.copy(card_id = "c_gone"), Instant.parse("2026-10-24T22:10:00Z"))
        val backup = header("ml_b", operator, Instant.parse("2026-09-03T18:00:00Z"))
        val mailbox = mailbox("m_studio" to audit, "m_studio" to smoke, "m_office" to backup)
        fun reader(
            id: String,
            machine: String = "m_studio",
            body: MailBody? = MailBody.Ready("# Hi"),
        ) =
            MailRules.slice(
                    context(
                        mailbox,
                        MailView(selected = MailMessageRef(machine, id)),
                        body,
                        liveCards = setOf("c_audit"),
                    )
                )
                .reader_!!
        val shown = reader("ml_a")
        assertEquals("# Hi", shown.body)
        assertFalse(shown.loading)
        assertEquals("Today 09:14", shown.sent_label)
        assertEquals(
            "Schedule · Isolated E2E · Studio · Claude Code Sonnet",
            shown.sender_detail,
        )
        assertTrue(shown.can_open_conversation)
        assertEquals("c_audit", shown.card_id)
        assertEquals("co_1", shown.checkout_id)
        assertEquals("Studio", shown.machine_name)
        assertTrue(shown.important)

        val gone = reader("ml_s", body = MailBody.Loading)
        assertTrue(gone.loading)
        assertEquals("", gone.body)
        assertFalse(gone.can_open_conversation)
        assertEquals("", gone.card_id)
        assertEquals("The conversation was deleted", gone.open_conversation_unavailable)
        assertEquals("Yesterday 22:10", gone.sent_label)

        val operatorMail = reader("ml_b", "m_office", MailBody.Unavailable("mbp-office is offline"))
        assertEquals("mbp-office is offline", operatorMail.unavailable)
        assertFalse(operatorMail.loading)
        assertEquals("Sent by backup.sh", operatorMail.open_conversation_unavailable)
        assertEquals("", operatorMail.checkout_id)
        assertEquals("Operator · mbp-office", operatorMail.sender_detail)
        assertEquals("mbp-office is offline", operatorMail.stale)

        assertNull(
            MailRules.slice(context(mailbox, MailView(selected = MailMessageRef("m_studio", "x"))))
                .reader_,
            "a message that is gone shows no reader",
        )
    }

    // --- Pending changes ---------------------------------------------------------------

    private fun entry(
        kind: OutboxKind,
        request: ByteArray,
        machine: String = "m_studio",
        state: OutboxState = OutboxState.OUTBOX_STATE_QUEUED,
        serverId: String = "",
    ) =
        OutboxEntry(
            command_id = "cmd",
            daemon_id = machine,
            kind = kind,
            request = request.toByteString(),
            optimistic_id = "mail_cmd",
            state = state,
            server_id = serverId,
        )

    private fun update(
        vararg ids: String,
        read: Boolean? = null,
        folder: MailFolder = MailFolder.MAIL_FOLDER_UNSPECIFIED,
    ) =
        UpdateMailRequest.ADAPTER.encode(
            UpdateMailRequest(ids = ids.toList(), read = read, folder = folder)
        )

    @Test
    fun pendingChangesShowAtOnceUntilTheMachineShowsThem() {
        val sent = now - 1.days
        val mail =
            mapOf(
                "m_studio" to
                    mapOf(
                        "ml_1" to header("ml_1", sent = sent),
                        "ml_2" to header("ml_2", sent = sent),
                    )
            )
        val queued = entry(OutboxKind.OUTBOX_KIND_UPDATE_MAIL, update("ml_1", "ml_9", read = true))
        val moved =
            entry(
                OutboxKind.OUTBOX_KIND_UPDATE_MAIL,
                update("ml_1", folder = MailFolder.MAIL_FOLDER_ARCHIVE),
            )
        val deleted =
            entry(
                OutboxKind.OUTBOX_KIND_DELETE_MAIL,
                DeleteMailRequest.ADAPTER.encode(DeleteMailRequest(ids = listOf("ml_2"))),
            )
        val failed = queued.copy(state = OutboxState.OUTBOX_STATE_FAILED)
        val shown = MailRules.overlay(mail, listOf(queued, moved, deleted))
        val one = shown.getValue("m_studio").getValue("ml_1")
        assertTrue(one.read)
        assertEquals(MailFolder.MAIL_FOLDER_ARCHIVE, one.folder, "changes apply in order")
        assertEquals(setOf("ml_1"), shown.getValue("m_studio").keys)
        assertEquals(mail, MailRules.overlay(mail, listOf(failed)), "a failed change shows nothing")

        assertFalse(MailRules.synced(queued, mail.getValue("m_studio")), "not accepted yet")
        val accepted = queued.copy(server_id = (now - 1.hours).toString())
        assertFalse(MailRules.synced(accepted, mail.getValue("m_studio")))
        val read = mail.getValue("m_studio").getValue("ml_1").copy(read = true)
        assertTrue(
            MailRules.synced(accepted, mapOf("ml_1" to read)),
            "every changed message shows it; a message that is gone is settled",
        )
        // Another device marked it unread after this change landed: the machine's state wins.
        val newer =
            mail.getValue("m_studio").getValue("ml_1").copy(state_changed_at = now.toString())
        assertTrue(MailRules.synced(accepted, mapOf("ml_1" to newer)))
        assertFalse(
            MailRules.overlay(mapOf("m_studio" to mapOf("ml_1" to newer)), listOf(accepted))
                .getValue("m_studio")
                .getValue("ml_1")
                .read
        )
        val acceptedDelete = deleted.copy(server_id = "accepted")
        assertFalse(MailRules.synced(acceptedDelete, mail.getValue("m_studio")))
        assertTrue(MailRules.synced(acceptedDelete, mapOf("ml_1" to read)))
    }
}
