package com.getdieter.core.channels

import com.getdieter.api.v1.ChannelAuthor
import com.getdieter.api.v1.ChannelClaim
import com.getdieter.api.v1.ChannelMember
import com.getdieter.api.v1.ChannelMessage
import com.getdieter.api.v1.ChannelSummary
import com.getdieter.client.v1.ChannelAuthorKind
import com.getdieter.client.v1.ChannelAuthorView
import com.getdieter.client.v1.ChannelClaimRow
import com.getdieter.client.v1.ChannelComposerState
import com.getdieter.client.v1.ChannelKindOption
import com.getdieter.client.v1.ChannelListRow
import com.getdieter.client.v1.ChannelMemberRow
import com.getdieter.client.v1.ChannelMessageKind
import com.getdieter.client.v1.ChannelPinRow
import com.getdieter.client.v1.ChannelPost
import com.getdieter.client.v1.ChannelPresence
import com.getdieter.client.v1.ChannelRecipientOption
import com.getdieter.client.v1.ChannelStreamRow
import com.getdieter.core.presentation.Ages
import com.getdieter.core.presentation.Counts
import com.getdieter.core.runtime.Timestamps
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

/** A stream's rows and where its unread part starts. */
data class ChannelRows(val rows: List<ChannelStreamRow>, val firstUnreadId: String?)

/**
 * The rules of agent channels as every client shows them: message kinds and their badges, author
 * avatars, Slack-style grouping, compact coordination events, delivery receipts, presence, claims,
 * and the composer. Stateless.
 */
object ChannelRules {
    /** Consecutive messages of one author within this window share one name line. */
    val GROUP_WINDOW = 5.minutes

    /** The daemon's limit on a message body, in UTF-8 bytes. */
    const val MAX_BODY_BYTES = 4096

    /** Avatar colours the apps provide. */
    const val COLORS = 8

    const val WAKE_HINT =
        "Wake starts a turn for idle recipients, within their wake budget. It needs recipients."

    const val EVERYONE_HINT =
        "Everyone: agents read it when their next turn starts. Nobody is interrupted."

    const val HERE_HINT =
        "@here: interrupts every running agent of the project, on every machine. Idle agents " +
            "don't get it."

    const val DIRECT_HINT =
        "Agents you pick get a direct message: a running agent reads it at once, an idle one in " +
            "its next turn."

    // --- Kinds ---------------------------------------------------------------------------

    fun kind(kind: String): ChannelMessageKind =
        when (kind.lowercase()) {
            "request" -> ChannelMessageKind.CHANNEL_MESSAGE_KIND_REQUEST
            "done" -> ChannelMessageKind.CHANNEL_MESSAGE_KIND_DONE
            "decision" -> ChannelMessageKind.CHANNEL_MESSAGE_KIND_DECISION
            "claim" -> ChannelMessageKind.CHANNEL_MESSAGE_KIND_CLAIM
            "hold" -> ChannelMessageKind.CHANNEL_MESSAGE_KIND_HOLD
            "release" -> ChannelMessageKind.CHANNEL_MESSAGE_KIND_RELEASE
            else -> ChannelMessageKind.CHANNEL_MESSAGE_KIND_NOTE
        }

    /** The daemon's name of a kind a person posts. */
    fun kindName(kind: ChannelMessageKind): String =
        when (kind) {
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_REQUEST -> "request"
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_DONE -> "done"
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_DECISION -> "decision"
            else -> "note"
        }

    /** The badge: "REQUEST", "DONE" or "DECISION"; notes and events have none. */
    fun kindLabel(kind: ChannelMessageKind): String =
        when (kind) {
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_REQUEST -> "REQUEST"
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_DONE -> "DONE"
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_DECISION -> "DECISION"
            else -> ""
        }

    /** The kinds a person posts, as the composer offers them. */
    val postKinds: List<ChannelKindOption> =
        listOf(
            ChannelKindOption(
                ChannelMessageKind.CHANNEL_MESSAGE_KIND_NOTE,
                "Note",
                "Information agents read when it is relevant.",
            ),
            ChannelKindOption(
                ChannelMessageKind.CHANNEL_MESSAGE_KIND_REQUEST,
                "Request",
                "Asks the recipients to do something.",
            ),
            ChannelKindOption(
                ChannelMessageKind.CHANNEL_MESSAGE_KIND_DONE,
                "Done",
                "Reports finished work.",
            ),
            ChannelKindOption(
                ChannelMessageKind.CHANNEL_MESSAGE_KIND_DECISION,
                "Decision",
                "Pinned, and returned to agents that check the files it names.",
            ),
        )

    // --- Authors -------------------------------------------------------------------------

    fun authorKind(kind: String): ChannelAuthorKind =
        when (kind.lowercase()) {
            "human" -> ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN
            "dieter" -> ChannelAuthorKind.CHANNEL_AUTHOR_KIND_DIETER
            else -> ChannelAuthorKind.CHANNEL_AUTHOR_KIND_AGENT
        }

    /** Up to two letters: the first letters of the first two words, else of one word. */
    fun initials(title: String): String {
        val words = title.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
        val letters =
            when {
                words.isEmpty() -> "?"
                words.size == 1 -> words[0].take(2)
                else -> "${words[0].first()}${words[1].first()}"
            }
        return letters.uppercase()
    }

    /** A card's avatar colour, the same on every client. */
    fun colorIndex(cardId: String): Int =
        if (cardId.isEmpty()) 0 else (cardId.hashCode() and Int.MAX_VALUE) % COLORS

    fun author(
        author: ChannelAuthor?,
        titles: Map<String, String> = emptyMap(),
    ): ChannelAuthorView {
        val kind = authorKind(author?.kind.orEmpty())
        val cardId = author?.card_id.orEmpty()
        val name =
            when (kind) {
                ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN -> "You"
                ChannelAuthorKind.CHANNEL_AUTHOR_KIND_DIETER -> "Dieter"
                else ->
                    author?.title?.ifBlank { null }
                        ?: titles[cardId]?.ifBlank { null }
                        ?: cardId.ifEmpty { "Agent" }
            }
        return ChannelAuthorView(
            kind = kind,
            name = name,
            initials =
                when (kind) {
                    ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN -> "Y"
                    ChannelAuthorKind.CHANNEL_AUTHOR_KIND_DIETER -> "D"
                    else -> initials(name)
                },
            harness = author?.harness.orEmpty(),
            model = author?.model.orEmpty(),
            card_id = cardId,
            color_index = colorIndex(cardId),
        )
    }

    /**
     * The name line's details: "codex · gpt-5 · mbp-office" for an agent ([machine] is where it
     * posted from), "you" for a person.
     */
    fun meta(author: ChannelAuthor?, machine: String = ""): String =
        when (authorKind(author?.kind.orEmpty())) {
            ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN -> "you"
            ChannelAuthorKind.CHANNEL_AUTHOR_KIND_DIETER -> ""
            else ->
                listOfNotNull(
                        author?.harness?.ifBlank { null },
                        author?.model?.ifBlank { null },
                        machine.ifBlank { null },
                    )
                    .joinToString(" · ")
        }

    /** Dieter's coordination events are compact rows, not messages. */
    fun isEvent(message: ChannelMessage): Boolean =
        authorKind(message.author?.kind.orEmpty()) == ChannelAuthorKind.CHANNEL_AUTHOR_KIND_DIETER

    private fun sameAuthor(a: ChannelMessage, b: ChannelMessage): Boolean {
        val left = a.author ?: return false
        val right = b.author ?: return false
        if (left.kind != right.kind) return false
        return when (authorKind(left.kind)) {
            ChannelAuthorKind.CHANNEL_AUTHOR_KIND_AGENT -> left.card_id == right.card_id
            ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN -> true
            ChannelAuthorKind.CHANNEL_AUTHOR_KIND_DIETER -> false
        }
    }

    /** [next] continues [previous]'s author group. */
    fun continues(previous: ChannelMessage?, next: ChannelMessage): Boolean {
        previous ?: return false
        if (isEvent(previous) || isEvent(next) || !sameAuthor(previous, next)) return false
        val before = Timestamps.parse(previous.created_at) ?: return false
        val after = Timestamps.parse(next.created_at) ?: return false
        val gap = after - before
        return !gap.isNegative() && gap <= GROUP_WINDOW
    }

    // --- Recipients and receipts ---------------------------------------------------------

    private fun title(cardId: String, titles: Map<String, String>): String =
        titles[cardId]?.ifBlank { null } ?: cardId

    /** "to Fix checkout tests, Review headers", or "@here"; empty for a channel post. */
    fun recipients(message: ChannelMessage, titles: Map<String, String>): String =
        when {
            message.here -> "@here"
            message.to_card_ids.isEmpty() -> ""
            else -> "to " + message.to_card_ids.joinToString(", ") { title(it, titles) }
        }

    /** How a message reached one recipient. */
    fun deliveryPhrase(mode: String): String =
        when (mode.lowercase()) {
            "pending" -> "not delivered yet"
            "steered" -> "steered into turn"
            "digest" -> "in next turn"
            "inbox" -> "read from inbox"
            "woke" -> "woke idle agent"
            else -> mode
        }

    /**
     * Each recipient's latest delivery: "Review headers: steered into turn · Fix checkout tests: in
     * next turn", at most three, then "+2 more".
     */
    fun receipt(message: ChannelMessage, titles: Map<String, String>): String {
        val latest = LinkedHashMap<String, String>()
        for (delivery in message.deliveries) {
            latest.remove(delivery.card_id)
            latest[delivery.card_id] = delivery.mode
        }
        if (latest.isEmpty()) return ""
        val shown =
            latest.entries.take(MAX_RECEIPTS).joinToString(" · ") { (card, mode) ->
                "${title(card, titles)}: ${deliveryPhrase(mode)}"
            }
        val more = latest.size - MAX_RECEIPTS
        return if (more > 0) "$shown · +$more more" else shown
    }

    private const val MAX_RECEIPTS = 3

    private val mention = Regex("agent (\\S+) \\('([^']*)'\\)", RegexOption.IGNORE_CASE)

    /** The other card a coordination event names ("agent c_1 ('Title')"), by title. */
    private fun mentioned(body: String, titles: Map<String, String>): String? =
        mention.find(body)?.let { match ->
            match.groupValues[2].ifBlank { null } ?: title(match.groupValues[1], titles)
        }

    private fun fileList(files: List<String>): String =
        when (files.size) {
            0 -> "files"
            1 -> files[0]
            else -> Counts.of(files.size, "file")
        }

    /**
     * A coordination event as one line: "Review headers changed src/a.ts, held by Add tiers", "Add
     * tiers is waiting for src/a.ts from Review headers", "Review headers released src/a.ts for Add
     * tiers", "Review headers claimed 2 files".
     */
    fun eventText(message: ChannelMessage, titles: Map<String, String>): String {
        val to = message.to_card_ids.firstOrNull()?.let { title(it, titles) } ?: "An agent"
        val files = fileList(message.files)
        val other = mentioned(message.body, titles)
        return when (kind(message.kind)) {
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_HOLD ->
                "$to changed $files, held by ${other ?: "another agent"}"
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_REQUEST ->
                "${other ?: "Another agent"} is waiting for $files from $to"
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_RELEASE ->
                "${other ?: "An agent"} released $files for $to"
            ChannelMessageKind.CHANNEL_MESSAGE_KIND_CLAIM -> "$to claimed $files"
            else -> message.body.substringBefore('\n').trim()
        }
    }

    // --- Stream rows ---------------------------------------------------------------------

    /**
     * [messages] (oldest first) as rows. The first unread message (after [seenSeq], not the user's)
     * starts a new group, where the "New" divider goes. [machine] names the machine an agent posted
     * from.
     */
    fun rows(
        messages: List<ChannelMessage>,
        seenSeq: Long,
        titles: Map<String, String>,
        machine: (String) -> String = { "" },
    ): ChannelRows {
        val firstUnread = messages.firstOrNull {
            it.seq > seenSeq &&
                authorKind(it.author?.kind.orEmpty()) != ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN
        }
        var previous: ChannelMessage? = null
        val rows = messages.map { message ->
            val event = isEvent(message)
            val kind = kind(message.kind)
            val continued = message !== firstUnread && continues(previous, message)
            previous = message
            ChannelStreamRow(
                id = message.id,
                seq = message.seq,
                kind = kind,
                event = event,
                continued = continued,
                author = author(message.author, titles),
                kind_label = if (event) "" else kindLabel(kind),
                body = if (event) eventText(message, titles) else message.body,
                files = message.files,
                recipients = if (event) "" else recipients(message, titles),
                direct = message.to_card_ids.isNotEmpty(),
                pinned = message.pinned,
                reply_count = message.reply_count,
                replies_label =
                    if (message.reply_count > 0) Counts.of(message.reply_count, "reply", "replies")
                    else "",
                receipt = receipt(message, titles),
                meta =
                    if (event) ""
                    else
                        meta(
                            message.author,
                            message.origin_daemon_id.ifEmpty { null }?.let(machine).orEmpty(),
                        ),
                created_at_millis =
                    Timestamps.parse(message.created_at)?.toEpochMilliseconds() ?: 0,
                thread_id = message.thread_id,
                here = message.here,
            )
        }
        return ChannelRows(rows, firstUnread?.id)
    }

    /** Pinned messages, newest first. */
    fun pins(messages: List<ChannelMessage>, titles: Map<String, String>): List<ChannelPinRow> =
        messages
            .filter { it.pinned }
            .sortedByDescending { it.seq }
            .map {
                ChannelPinRow(
                    message_id = it.id,
                    body = it.body,
                    author = author(it.author, titles).name,
                    created_at_millis = Timestamps.parse(it.created_at)?.toEpochMilliseconds() ?: 0,
                    kind = kind(it.kind),
                )
            }

    // --- Members and claims --------------------------------------------------------------

    fun presence(status: String): ChannelPresence =
        when (status.lowercase()) {
            "running" -> ChannelPresence.CHANNEL_PRESENCE_RUNNING
            "waiting" -> ChannelPresence.CHANNEL_PRESENCE_WAITING
            "failed" -> ChannelPresence.CHANNEL_PRESENCE_FAILED
            else -> ChannelPresence.CHANNEL_PRESENCE_IDLE
        }

    /** "Running", "Waiting on src/a.ts", "Waiting on 2 files", "Idle" or "Failed". */
    fun presenceLabel(member: ChannelMember): String =
        when (presence(member.status)) {
            ChannelPresence.CHANNEL_PRESENCE_RUNNING -> "Running"
            ChannelPresence.CHANNEL_PRESENCE_WAITING ->
                if (member.waiting_on.isEmpty()) "Waiting"
                else "Waiting on ${fileList(member.waiting_on)}"
            ChannelPresence.CHANNEL_PRESENCE_FAILED -> "Failed"
            ChannelPresence.CHANNEL_PRESENCE_IDLE -> "Idle"
        }

    /**
     * Running first, then waiting, idle and failed; by title within each. [machine] names the
     * machine that runs a card.
     */
    fun members(
        members: List<ChannelMember>,
        machine: (String) -> String = { "" },
    ): List<ChannelMemberRow> =
        members
            .sortedWith(
                compareBy(
                    { presenceOrder(presence(it.status)) },
                    { it.title.lowercase() },
                    { it.card_id },
                )
            )
            .map { member ->
                val title = member.title.ifBlank { member.card_id }
                val host = member.daemon_id.ifEmpty { null }?.let(machine).orEmpty()
                ChannelMemberRow(
                    card_id = member.card_id,
                    title = title,
                    initials = initials(title),
                    color_index = colorIndex(member.card_id),
                    harness = member.harness,
                    model = member.model,
                    presence = presence(member.status),
                    presence_label = presenceLabel(member),
                    detail =
                        (listOf(member.harness, member.model, host).filter { it.isNotBlank() } +
                                listOfNotNull(
                                    member.holds
                                        .takeIf { it.isNotEmpty() }
                                        ?.let { "holds ${fileList(it)}" }
                                ))
                            .joinToString(" · "),
                    holds = member.holds,
                    waiting_on = member.waiting_on,
                    enabled = member.enabled,
                    board_id = member.board_id,
                    machine = host,
                )
            }

    private fun presenceOrder(presence: ChannelPresence) =
        when (presence) {
            ChannelPresence.CHANNEL_PRESENCE_RUNNING -> 0
            ChannelPresence.CHANNEL_PRESENCE_WAITING -> 1
            ChannelPresence.CHANNEL_PRESENCE_IDLE -> 2
            ChannelPresence.CHANNEL_PRESENCE_FAILED -> 3
        }

    /**
     * Live claims on every machine, longest held first. Another machine's claim is advisory: it
     * blocks writes only in that machine's checkout. [machine] names a machine.
     */
    fun claims(
        claims: List<ChannelClaim>,
        titles: Map<String, String>,
        now: Instant,
        machine: (String) -> String = { "" },
    ): List<ChannelClaimRow> =
        claims
            .sortedWith(
                compareBy({ Timestamps.parse(it.since) ?: Instant.DISTANT_FUTURE }, { it.path })
            )
            .map { claim ->
                val holder = claim.card_title.ifBlank { null } ?: title(claim.card_id, titles)
                val since = Timestamps.parse(claim.since)
                ChannelClaimRow(
                    id = "${claim.card_id}:${claim.path}",
                    path = claim.path,
                    card_id = claim.card_id,
                    holder = holder,
                    holder_initials = initials(holder),
                    holder_color_index = colorIndex(claim.card_id),
                    since_millis = since?.toEpochMilliseconds() ?: 0,
                    held_label =
                        since?.let { "held " + (Ages.span(now - it)?.compact ?: "<1m") }.orEmpty(),
                    waiting_label =
                        when (claim.waiting_card_ids.size) {
                            0 -> ""
                            1 -> "${title(claim.waiting_card_ids[0], titles)} waiting"
                            else -> "${claim.waiting_card_ids.size} waiting"
                        },
                    waiting = claim.waiting_card_ids.size,
                    machine = claim.daemon_id.ifEmpty { null }?.let(machine).orEmpty(),
                    advisory = claim.remote,
                )
            }

    /** "1 live claim · 1 waiting"; empty without claims. */
    fun claimsSummary(claims: List<ChannelClaim>): String {
        if (claims.isEmpty()) return ""
        val waiting = claims.flatMap { it.waiting_card_ids }.toSet().size
        val held = Counts.of(claims.size, "live claim")
        return if (waiting > 0) "$held · $waiting waiting" else held
    }

    /** "Claims", or "Claims · 2". */
    fun tab(name: String, count: Int): String = if (count > 0) "$name · $count" else name

    // --- Lists and the composer ----------------------------------------------------------

    /** "4 agents · 1 running · 2 claims", or "Off". */
    fun listDetail(summary: ChannelSummary): String {
        if (!summary.enabled) return "Off"
        val running =
            summary.members.count {
                presence(it.status) == ChannelPresence.CHANNEL_PRESENCE_RUNNING
            }
        return listOfNotNull(
                Counts.of(summary.members.size, "agent"),
                running.takeIf { it > 0 }?.let { "$it running" },
                summary.claims.takeIf { it > 0 }?.let { Counts.of(it, "claim") },
            )
            .joinToString(" · ")
    }

    fun listRow(summary: ChannelSummary, selected: Boolean): ChannelListRow =
        ChannelListRow(
            project_id = summary.project_id,
            name = summary.project_name.ifBlank { summary.project_id },
            enabled = summary.enabled,
            unread = if (summary.enabled) summary.unread else 0,
            claims = summary.claims,
            members = summary.members.size,
            running =
                summary.members.count {
                    presence(it.status) == ChannelPresence.CHANNEL_PRESENCE_RUNNING
                },
            detail = listDetail(summary),
            selected = selected,
            last_message_at_millis =
                Timestamps.parse(summary.last_message_at)?.toEpochMilliseconds() ?: 0,
        )

    /** "3", "99+"; empty for none. */
    fun unreadLabel(count: Int): String = Counts.badge(count)

    /**
     * The composer of a channel named [name], read from [machineName] (null before a machine lists
     * it): it posts while the channel is on and that machine is reachable; direct messages go to
     * the members whose setting is on, on any machine.
     */
    fun composer(
        name: String,
        enabled: Boolean,
        reachable: Boolean,
        machineName: String?,
        members: List<ChannelMember>,
        sending: Boolean,
        machine: (String) -> String = { "" },
    ): ChannelComposerState {
        val reason =
            when {
                machineName == null -> "No reachable machine has this channel yet."
                !reachable -> "$machineName is not reachable."
                !enabled -> "Agent channels are off for this project. Turn them on in its settings."
                else -> ""
            }
        return ChannelComposerState(
            can_post = reason.isEmpty(),
            placeholder = "Message #$name",
            disabled_reason = reason,
            recipients =
                members(members.filter { it.enabled }, machine).map {
                    ChannelRecipientOption(
                        card_id = it.card_id,
                        title = it.title,
                        presence = it.presence,
                        machine = it.machine,
                    )
                },
            kinds = postKinds,
            wake_hint = WAKE_HINT,
            max_body_bytes = MAX_BODY_BYTES,
            sending = sending,
            everyone_hint = EVERYONE_HINT,
            here_hint = HERE_HINT,
            direct_hint = DIRECT_HINT,
        )
    }

    /** Why [post] cannot be sent, or null when it can. */
    fun postProblem(post: ChannelPost): String? =
        bodyProblem(post.body)
            ?: when {
                post.here && post.to_card_ids.isNotEmpty() ->
                    "@here already reaches every running agent. Remove the recipients."
                post.wake && post.to_card_ids.isEmpty() -> "Choose who to wake."
                else -> null
            }

    /** Why [body] cannot be posted, or null when it can. */
    fun bodyProblem(body: String): String? {
        val trimmed = body.trim()
        return when {
            trimmed.isEmpty() -> "Write a message first."
            trimmed.encodeToByteArray().size > MAX_BODY_BYTES ->
                "A message is at most $MAX_BODY_BYTES bytes."
            else -> null
        }
    }
}
