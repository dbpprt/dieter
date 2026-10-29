package com.getdieter.core.mail

import com.getdieter.api.v1.DeleteMailRequest
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.MailFolder
import com.getdieter.api.v1.MailHeader
import com.getdieter.api.v1.MailImportance
import com.getdieter.api.v1.MailSender
import com.getdieter.api.v1.MailSenderKind
import com.getdieter.api.v1.UpdateMailRequest
import com.getdieter.client.v1.MailBox
import com.getdieter.client.v1.MailBoxRow
import com.getdieter.client.v1.MailFilter
import com.getdieter.client.v1.MailFilterOption
import com.getdieter.client.v1.MailMessageRef
import com.getdieter.client.v1.MailPreferences
import com.getdieter.client.v1.MailReader
import com.getdieter.client.v1.MailRow
import com.getdieter.client.v1.MailSection
import com.getdieter.client.v1.MailSenderStyle
import com.getdieter.client.v1.MailSlice
import com.getdieter.core.channels.ChannelRules
import com.getdieter.core.presentation.Counts
import com.getdieter.core.runtime.Timestamps
import com.getdieter.core.selection.Selections
import com.getdieter.core.v1.OutboxEntry
import com.getdieter.core.v1.OutboxKind
import com.getdieter.core.v1.OutboxState
import kotlin.time.Instant

/** One message as the mailbox shows it: its header with this device's pending changes applied. */
data class MailItem(val machineId: String, val header: MailHeader) {
    val ref: MailMessageRef
        get() = MailMessageRef(machineId, header.id)

    /** When it was sent; null when the daemon's time does not parse. Read once, as lists sort. */
    val sentAt: Instant? by lazy { Timestamps.parse(header.sent_at) }
}

/** A machine that holds mail, as the mailbox names it. */
data class MailMachine(
    val id: String,
    val name: String,
    /** "Studio is offline" while its view may be old; null while current. */
    val stale: String? = null,
    /** Commands and body reads reach it now. */
    val reachable: Boolean = false,
)

/** The account-wide mailbox: every machine's messages with that machine's sync state. */
data class MailProjection(
    val items: List<MailItem> = emptyList(),
    val machines: Map<String, MailMachine> = emptyMap(),
) {
    private val byRef: Map<MailMessageRef, MailItem> by lazy { items.associateBy { it.ref } }

    fun item(ref: MailMessageRef): MailItem? = byRef[ref]

    fun machine(id: String): MailMachine = machines[id] ?: MailMachine(id, id)
}

/** What the reading pane shows of a message's body. */
sealed interface MailBody {
    data class Ready(val text: String) : MailBody

    data object Loading : MailBody

    /** "Studio is offline", or why the read failed. */
    data class Unavailable(val reason: String) : MailBody
}

/** One view's mailbox choices. */
data class MailView(
    val box: MailBox = MailBox.MAIL_BOX_INBOX,
    val selected: MailMessageRef? = null,
    val search: String = "",
    val filter: MailFilter = MailFilter(),
    /** The mailbox is on screen. */
    val active: Boolean = false,
    /** Why this view's last command failed. */
    val actionError: String? = null,
)

/** Everything a mail slice is derived from. */
data class MailContext(
    val mailbox: MailProjection,
    val view: MailView,
    val preferences: MailPreferences,
    /** The selected message's body. */
    val body: MailBody?,
    /** Conversations the account view shows now, by ID. */
    val liveCards: Set<String>,
    val now: Instant,
    /** The device zone's offset from UTC, in seconds, at an instant. */
    val offset: (Instant) -> Int,
    /** A machine's loaded agent catalog. */
    val harnesses: (String) -> List<Harness> = { emptyList() },
    /** Machines are being read and nothing is listed yet. */
    val loading: Boolean = false,
    /** The newest mail change this device could not deliver. */
    val failure: String? = null,
)

/**
 * The mailbox's rules: folders and views, counts, order, date groups, labels, search, filters, the
 * reading pane, and this device's pending changes over the machines' headers.
 */
object MailRules {
    /** IDs per UpdateMail or DeleteMail call. */
    const val BATCH = 500

    val BOXES =
        listOf(
            MailBox.MAIL_BOX_INBOX,
            MailBox.MAIL_BOX_FLAGGED,
            MailBox.MAIL_BOX_UNREAD,
            MailBox.MAIL_BOX_ARCHIVE,
            MailBox.MAIL_BOX_TRASH,
        )

    // --- Folders and views -------------------------------------------------------------

    /** A header's folder; one the daemon left unset is the Inbox. */
    fun folder(header: MailHeader): MailFolder =
        header.folder.takeIf { it != MailFolder.MAIL_FOLDER_UNSPECIFIED }
            ?: MailFolder.MAIL_FOLDER_INBOX

    /**
     * Inbox, Archive and Trash are folders; Flagged is flagged mail outside the Trash, Unread is
     * unread Inbox mail.
     */
    fun inBox(header: MailHeader, box: MailBox): Boolean {
        val folder = folder(header)
        return when (box) {
            MailBox.MAIL_BOX_INBOX -> folder == MailFolder.MAIL_FOLDER_INBOX
            MailBox.MAIL_BOX_FLAGGED -> header.flagged && folder != MailFolder.MAIL_FOLDER_TRASH
            MailBox.MAIL_BOX_UNREAD -> !header.read && folder == MailFolder.MAIL_FOLDER_INBOX
            MailBox.MAIL_BOX_ARCHIVE -> folder == MailFolder.MAIL_FOLDER_ARCHIVE
            MailBox.MAIL_BOX_TRASH -> folder == MailFolder.MAIL_FOLDER_TRASH
        }
    }

    fun title(box: MailBox): String =
        when (box) {
            MailBox.MAIL_BOX_INBOX -> "Inbox"
            MailBox.MAIL_BOX_FLAGGED -> "Flagged"
            MailBox.MAIL_BOX_UNREAD -> "Unread"
            MailBox.MAIL_BOX_ARCHIVE -> "Archive"
            MailBox.MAIL_BOX_TRASH -> "Trash"
        }

    /** Unread Inbox messages on every machine: the navigation badge. */
    fun unread(items: List<MailItem>): Int = items.count {
        inBox(it.header, MailBox.MAIL_BOX_UNREAD)
    }

    /** Each box with its counts; Flagged and Trash count their total, the others what is unread. */
    fun boxes(items: List<MailItem>, selected: MailBox): List<MailBoxRow> = BOXES.map { box ->
        val members = items.filter { inBox(it.header, box) }
        val unread = members.count { !it.header.read }
        val counted =
            if (box == MailBox.MAIL_BOX_FLAGGED || box == MailBox.MAIL_BOX_TRASH) members.size
            else unread
        MailBoxRow(
            box = box,
            title = title(box),
            unread = unread,
            total = members.size,
            count_label = Counts.badge(counted),
            selected = box == selected,
        )
    }

    /** Newest first, ties by ID as the daemon lists them. */
    val ORDER: Comparator<MailItem> =
        compareByDescending<MailItem> {
                it.sentAt?.toEpochMilliseconds() ?: Long.MIN_VALUE
            }
            .thenByDescending { it.header.id }
            .thenBy { it.machineId }

    // --- Senders -----------------------------------------------------------------------

    private fun agent(sender: MailSender): Boolean =
        sender.kind != MailSenderKind.MAIL_SENDER_KIND_OPERATOR

    /**
     * Who a message is from: the schedule, else the conversation, else the operator's label, else
     * "Operator on Studio".
     */
    fun sender(sender: MailSender?, machine: String): String {
        val from = sender ?: MailSender()
        return from.schedule_name.trim().ifEmpty { null }
            ?: from.title.trim().ifEmpty { null }
            ?: from.label.trim().ifEmpty { null }
            ?: if (agent(from)) "Agent on $machine" else "Operator on $machine"
    }

    fun style(sender: MailSender?): MailSenderStyle {
        val from = sender ?: MailSender()
        return when {
            from.schedule_id.isNotBlank() -> MailSenderStyle.MAIL_SENDER_STYLE_SCHEDULE
            from.scope == "chat" -> MailSenderStyle.MAIL_SENDER_STYLE_CHAT
            !agent(from) -> MailSenderStyle.MAIL_SENDER_STYLE_OPERATOR
            else -> MailSenderStyle.MAIL_SENDER_STYLE_CARD
        }
    }

    /** Groups the sender filter: "schedule:<id>", "card:<id>", or "operator:<label>". */
    fun senderKey(sender: MailSender?, machineId: String): String {
        val from = sender ?: MailSender()
        return when {
            from.schedule_id.isNotBlank() -> "schedule:${from.schedule_id}"
            agent(from) -> "card:${from.card_id}"
            else ->
                "operator:" +
                    (from.label.trim().ifEmpty { null }
                        ?: from.device_id.ifEmpty { null }
                        ?: machineId)
        }
    }

    /** The agent's name as its machine's catalog lists it, else its ID. */
    fun harnessName(harness: String, catalog: List<Harness>): String =
        Selections.harness(catalog, harness)?.name?.ifBlank { null } ?: harness

    /**
     * The agent and model: "Claude Code Sonnet", "Claude Sonnet 4.5" where the model already names
     * its maker, or the agent alone.
     */
    fun agentLabel(harness: String, model: String, catalog: List<Harness>): String {
        val agent = harnessName(harness, catalog)
        val known = Selections.harness(catalog, harness)
        val modelName =
            (known?.let { Selections.model(it, model) }?.name?.ifBlank { null } ?: model).trim()
        val maker = agent.substringBefore(' ')
        return when {
            modelName.isEmpty() -> agent
            agent.isEmpty() -> modelName
            modelName.startsWith(maker, ignoreCase = true) -> modelName
            else -> "$agent $modelName"
        }
    }

    /** The list's second line: "dieter · Studio · Claude Code". */
    fun senderDetail(item: MailItem, machine: MailMachine, catalog: List<Harness>): String {
        val from = item.header.sender ?: MailSender()
        return listOf(
                from.project_name,
                machine.name,
                if (agent(from)) harnessName(from.harness, catalog) else "",
            )
            .filter { it.isNotBlank() }
            .joinToString(" · ")
    }

    /** The reading pane's line: "Schedule · dieter · Studio · Claude Code Sonnet". */
    fun readerDetail(item: MailItem, machine: MailMachine, catalog: List<Harness>): String {
        val from = item.header.sender ?: MailSender()
        val kind =
            when (style(from)) {
                MailSenderStyle.MAIL_SENDER_STYLE_SCHEDULE -> "Schedule"
                MailSenderStyle.MAIL_SENDER_STYLE_CHAT -> "Chat"
                MailSenderStyle.MAIL_SENDER_STYLE_OPERATOR -> "Operator"
                MailSenderStyle.MAIL_SENDER_STYLE_CARD -> "Card"
            }
        return listOf(
                kind,
                from.project_name,
                machine.name,
                if (agent(from)) agentLabel(from.harness, from.model, catalog) else "",
            )
            .filter { it.isNotBlank() }
            .joinToString(" · ")
    }

    // --- Times -------------------------------------------------------------------------

    /** "09:14" today, "Mon" within the last week, "12 Oct" this year, else "12 Oct 2025". */
    fun timeLabel(at: Instant?, now: Instant, offset: (Instant) -> Int): String {
        at ?: return ""
        val zone = offset(at)
        val day = LocalDay.of(at, zone)
        val today = LocalDay.of(now, offset(now))
        val ago = today.epochDay - day.epochDay
        return when {
            ago == 0L -> MailDates.clock(at, zone)
            ago in 1..6 -> MailDates.weekday(day)
            day.year == today.year -> MailDates.dayMonth(day)
            else -> "${MailDates.dayMonth(day)} ${day.year}"
        }
    }

    /** "Today 09:14", "Yesterday 22:10", else "Sun 25 Oct 2026, 09:14". */
    fun sentLabel(at: Instant?, now: Instant, offset: (Instant) -> Int): String {
        at ?: return ""
        val zone = offset(at)
        val day = LocalDay.of(at, zone)
        val ago = LocalDay.of(now, offset(now)).epochDay - day.epochDay
        val clock = MailDates.clock(at, zone)
        return when (ago) {
            0L -> "Today $clock"
            1L -> "Yesterday $clock"
            else -> "${MailDates.weekday(day)} ${MailDates.dayMonth(day)} ${day.year}, $clock"
        }
    }

    /**
     * The date group of [at]: Today, Yesterday, This week, Last week (weeks start on Monday), then
     * its month. A time ahead of the device's clock is today's.
     */
    fun section(at: Instant?, now: Instant, offset: (Instant) -> Int): Pair<String, String> {
        at ?: return "earlier" to "Earlier"
        val day = LocalDay.of(at, offset(at))
        val today = LocalDay.of(now, offset(now))
        return when {
            day.epochDay >= today.epochDay -> "today" to "Today"
            day.epochDay == today.epochDay - 1 -> "yesterday" to "Yesterday"
            day.epochDay >= today.weekStart -> "this-week" to "This week"
            day.epochDay >= today.weekStart - 7 -> "last-week" to "Last week"
            else -> MailDates.monthId(day) to MailDates.monthTitle(day)
        }
    }

    // --- Search and filters ------------------------------------------------------------

    /** Case-insensitive: the subject, the sender, the project, or the preview contains [query]. */
    fun matches(item: MailItem, machine: MailMachine, query: String): Boolean {
        val needle = query.trim()
        if (needle.isEmpty()) return true
        val header = item.header
        return listOf(
                header.subject,
                sender(header.sender, machine.name),
                header.sender?.project_name.orEmpty(),
                header.preview,
            )
            .any { it.contains(needle, ignoreCase = true) }
    }

    fun matches(item: MailItem, filter: MailFilter): Boolean {
        val header = item.header
        return (filter.project_id.isEmpty() || header.sender?.project_id == filter.project_id) &&
            (filter.daemon_id.isEmpty() || item.machineId == filter.daemon_id) &&
            (filter.sender_key.isEmpty() ||
                senderKey(header.sender, item.machineId) == filter.sender_key) &&
            (!filter.important_only || important(header))
    }

    fun filtered(filter: MailFilter): Boolean =
        filter.project_id.isNotEmpty() ||
            filter.daemon_id.isNotEmpty() ||
            filter.sender_key.isNotEmpty() ||
            filter.important_only

    fun important(header: MailHeader): Boolean =
        header.importance == MailImportance.MAIL_IMPORTANCE_HIGH

    private fun options(entries: Map<String, String>, selected: String): List<MailFilterOption> =
        entries.entries.sortedWith(compareBy({ it.value.lowercase() }, { it.key })).map {
            MailFilterOption(it.key, it.value, it.key == selected)
        }

    // --- Empty states ------------------------------------------------------------------

    const val NO_MAIL_TITLE = "No mail yet"
    const val NO_MAIL_DETAIL =
        "Agents in cards, chats and schedules created with Mail access send their reports here."

    /** What a list without rows says: why nothing matches, else what the box holds. */
    fun empty(view: MailView, anyMail: Boolean, boxEmpty: Boolean): Pair<String, String> {
        val query = view.search.trim()
        return when {
            !boxEmpty && query.isNotEmpty() -> "No results" to "Nothing matches “$query”."
            !boxEmpty -> "No results" to "No message in ${title(view.box)} matches the filter."
            else ->
                when (view.box) {
                    MailBox.MAIL_BOX_INBOX ->
                        if (anyMail) "Inbox is empty" to "New reports from your agents arrive here."
                        else NO_MAIL_TITLE to NO_MAIL_DETAIL
                    MailBox.MAIL_BOX_FLAGGED ->
                        "No flagged mail" to "Flag a message to keep it at hand."
                    MailBox.MAIL_BOX_UNREAD -> "No unread mail" to "You have read every message."
                    MailBox.MAIL_BOX_ARCHIVE ->
                        "Archive is empty" to "Archived messages stay here until you delete them."
                    MailBox.MAIL_BOX_TRASH ->
                        "Trash is empty" to "Deleted mail stays here for 30 days."
                }
        }
    }

    // --- Rows and the reading pane -----------------------------------------------------

    fun row(context: MailContext, item: MailItem): MailRow {
        val header = item.header
        val machine = context.mailbox.machine(item.machineId)
        val catalog = context.harnesses(item.machineId)
        val sent = item.sentAt
        val name = sender(header.sender, machine.name)
        val time = timeLabel(sent, context.now, context.offset)
        return MailRow(
            ref = item.ref,
            sender = name,
            sender_detail = senderDetail(item, machine, catalog),
            sender_style = style(header.sender),
            harness = header.sender?.takeIf(::agent)?.harness.orEmpty(),
            initials = ChannelRules.initials(name),
            sender_key = senderKey(header.sender, item.machineId),
            subject = header.subject,
            preview = header.preview,
            time_label = time,
            sent_at_millis = sent?.toEpochMilliseconds() ?: 0,
            read = header.read,
            flagged = header.flagged,
            important = important(header),
            folder = folder(header),
            stale = machine.stale.orEmpty(),
            selected = item.ref == context.view.selected,
            accessibility_label = accessibilityLabel(header, name, time, machine.stale),
        )
    }

    /** "Unread, important. Nightly dependency audit: Dependency audit …, 09:14". */
    fun accessibilityLabel(
        header: MailHeader,
        sender: String,
        time: String,
        stale: String? = null,
    ): String {
        val states =
            listOfNotNull(
                "unread".takeIf { !header.read },
                "important".takeIf { important(header) },
                "flagged".takeIf { header.flagged },
            )
        val prefix =
            if (states.isEmpty()) ""
            else states.joinToString(", ").replaceFirstChar { it.uppercaseChar() } + ". "
        val line = "$prefix$sender: ${header.subject}" + if (time.isEmpty()) "" else ", $time"
        return if (stale.isNullOrEmpty()) line else "$line. $stale"
    }

    fun reader(context: MailContext, item: MailItem): MailReader {
        val header = item.header
        val from = header.sender ?: MailSender()
        val machine = context.mailbox.machine(item.machineId)
        val catalog = context.harnesses(item.machineId)
        val name = sender(from, machine.name)
        val live = agent(from) && from.card_id.isNotEmpty() && from.card_id in context.liveCards
        val body = context.body
        return MailReader(
            ref = item.ref,
            subject = header.subject,
            sender = name,
            sender_detail = readerDetail(item, machine, catalog),
            sender_style = style(from),
            harness = if (agent(from)) from.harness else "",
            initials = ChannelRules.initials(name),
            sent_label = sentLabel(item.sentAt, context.now, context.offset),
            read = header.read,
            flagged = header.flagged,
            important = important(header),
            folder = folder(header),
            body = (body as? MailBody.Ready)?.text.orEmpty(),
            loading = body == null || body == MailBody.Loading,
            unavailable = (body as? MailBody.Unavailable)?.reason.orEmpty(),
            card_id = if (live) from.card_id else "",
            can_open_conversation = live,
            open_conversation_unavailable =
                when {
                    live -> ""
                    agent(from) -> "The conversation was deleted"
                    from.label.isNotBlank() -> "Sent by ${from.label.trim()}"
                    else -> "Sent by an operator on ${machine.name}"
                },
            checkout_id = if (agent(from)) from.checkout_id else "",
            machine_name = machine.name,
            stale = machine.stale.orEmpty(),
        )
    }

    /** What [view] lists of [mailbox]: its box after search and filter, newest first. */
    fun listed(mailbox: MailProjection, view: MailView): List<MailItem> =
        mailbox.items
            .filter {
                inBox(it.header, view.box) &&
                    matches(it, view.filter) &&
                    matches(it, mailbox.machine(it.machineId), view.search)
            }
            .sortedWith(ORDER)

    /** The mail surface's slice. */
    fun slice(context: MailContext): MailSlice {
        val view = context.view
        val items = context.mailbox.items
        val unread = unread(items)
        val unreadLabel = Counts.badge(unread)
        val inBox = items.filter { inBox(it.header, view.box) }
        val listed = listed(context.mailbox, view)
        val sections = LinkedHashMap<String, Pair<String, MutableList<MailRow>>>()
        for (item in listed) {
            val (id, title) = section(item.sentAt, context.now, context.offset)
            sections.getOrPut(id) { title to mutableListOf() }.second += row(context, item)
        }
        val (emptyTitle, emptyDetail) =
            if (listed.isNotEmpty() || context.loading) "" to ""
            else empty(view, items.isNotEmpty(), inBox.isEmpty())
        val names = context.mailbox
        return MailSlice(
            boxes = boxes(items, view.box),
            box = view.box,
            search = view.search,
            filter = view.filter,
            projects =
                options(
                    inBox
                        .mapNotNull { item ->
                            item.header.sender
                                ?.takeIf { it.project_id.isNotEmpty() }
                                ?.let { it.project_id to it.project_name.ifBlank { it.project_id } }
                        }
                        .toMap(),
                    view.filter.project_id,
                ),
            machines =
                options(
                    inBox.associate { it.machineId to names.machine(it.machineId).name },
                    view.filter.daemon_id,
                ),
            senders =
                options(
                    inBox.associate {
                        senderKey(it.header.sender, it.machineId) to
                            sender(it.header.sender, names.machine(it.machineId).name)
                    },
                    view.filter.sender_key,
                ),
            sections = sections.map { (id, value) -> MailSection(id, value.first, value.second) },
            count = listed.size,
            reader_ = view.selected?.let(context.mailbox::item)?.let { reader(context, it) },
            unread = unread,
            unread_label = unreadLabel,
            app_badge = if (context.preferences.app_badge) unreadLabel else "",
            preferences = context.preferences,
            loading = context.loading && listed.isEmpty(),
            empty_title = emptyTitle,
            empty_detail = emptyDetail,
            action_error = view.actionError ?: context.failure.orEmpty(),
        )
    }

    // --- This device's pending changes -------------------------------------------------

    fun changesMail(entry: OutboxEntry): Boolean =
        entry.kind == OutboxKind.OUTBOX_KIND_UPDATE_MAIL ||
            entry.kind == OutboxKind.OUTBOX_KIND_DELETE_MAIL

    fun updateRequest(entry: OutboxEntry): UpdateMailRequest? =
        if (entry.kind == OutboxKind.OUTBOX_KIND_UPDATE_MAIL)
            runCatching { UpdateMailRequest.ADAPTER.decode(entry.request) }.getOrNull()
        else null

    fun deleteRequest(entry: OutboxEntry): DeleteMailRequest? =
        if (entry.kind == OutboxKind.OUTBOX_KIND_DELETE_MAIL)
            runCatching { DeleteMailRequest.ADAPTER.decode(entry.request) }.getOrNull()
        else null

    /** [header] already shows [request]'s change. */
    private fun shows(header: MailHeader, request: UpdateMailRequest): Boolean =
        (request.read == null || header.read == request.read) &&
            (request.flagged == null || header.flagged == request.flagged) &&
            (request.folder == MailFolder.MAIL_FOLDER_UNSPECIFIED ||
                folder(header) == request.folder)

    /**
     * The machine reports [header] as the accepted [entry] left it or changed since: its state is
     * as new as the daemon's answer.
     */
    private fun settled(entry: OutboxEntry, header: MailHeader): Boolean {
        if (entry.server_id.isEmpty()) return false
        val accepted = Timestamps.parse(entry.server_id) ?: return false
        val changed = Timestamps.parse(header.state_changed_at) ?: return false
        return changed >= accepted
    }

    /**
     * True once the machine's [headers] show the accepted mail change [entry]: every message it
     * changed shows the change, changed again since, or is gone; every message it deleted is gone.
     */
    fun synced(entry: OutboxEntry, headers: Map<String, MailHeader>): Boolean {
        if (entry.server_id.isEmpty()) return false
        updateRequest(entry)?.let { request ->
            return request.ids.all { id ->
                val header = headers[id]
                header == null || shows(header, request) || settled(entry, header)
            }
        }
        deleteRequest(entry)?.let { request ->
            return request.ids.none { it in headers }
        }
        return true
    }

    /**
     * Every machine's headers with this device's mail changes applied in order: queued and accepted
     * ones until the machine shows them; failed ones not at all.
     */
    fun overlay(
        mail: Map<String, Map<String, MailHeader>>,
        entries: List<OutboxEntry>,
    ): Map<String, Map<String, MailHeader>> {
        val pending = entries.filter {
            changesMail(it) && it.state != OutboxState.OUTBOX_STATE_FAILED
        }
        if (pending.isEmpty()) return mail
        val result = HashMap(mail)
        for (entry in pending) {
            val headers = result[entry.daemon_id] ?: continue
            val next = HashMap(headers)
            updateRequest(entry)?.let { request ->
                for (id in request.ids) {
                    val header = next[id] ?: continue
                    if (settled(entry, header)) continue
                    next[id] =
                        header.copy(
                            read = request.read ?: header.read,
                            flagged = request.flagged ?: header.flagged,
                            folder =
                                request.folder.takeIf { it != MailFolder.MAIL_FOLDER_UNSPECIFIED }
                                    ?: header.folder,
                        )
                }
            }
            deleteRequest(entry)?.let { request -> request.ids.forEach(next::remove) }
            result[entry.daemon_id] = next
        }
        return result
    }

    /** [mail] (machine ID → its headers) as the mailbox lists it, with [machines] named. */
    fun project(
        mail: Map<String, Map<String, MailHeader>>,
        machines: Map<String, MailMachine>,
    ): MailProjection =
        MailProjection(
            items =
                mail.flatMap { (machineId, headers) ->
                    headers.values.map { MailItem(machineId, it) }
                },
            machines = machines,
        )
}
