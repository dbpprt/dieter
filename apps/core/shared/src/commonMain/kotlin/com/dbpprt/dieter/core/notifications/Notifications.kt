package com.dbpprt.dieter.core.notifications

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.board.Runtimes
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.presentation.Counts

enum class NotificationStyle { COMPACT, DETAILED }

/** Device-local notification choices. Review alerts need boards opted in. */
data class NotificationSettings(
    val enabled: Boolean = true,
    val runningChats: Boolean = true,
    val successfulChats: Boolean = true,
    val attentionChats: Boolean = true,
    val reviewCards: Boolean = true,
    val style: NotificationStyle = NotificationStyle.DETAILED,
    val resultPreviews: Boolean = true,
    val liveStatus: Boolean = true,
    val boardIds: Set<String> = emptySet(),
) {
    fun save(settings: DeviceSettings) {
        settings.putString("notifications.enabled", enabled.toString())
        settings.putString("notifications.running_chats", runningChats.toString())
        settings.putString("notifications.successful_chats", successfulChats.toString())
        settings.putString("notifications.attention_chats", attentionChats.toString())
        settings.putString("notifications.review_cards", reviewCards.toString())
        settings.putString("notifications.style", style.name)
        settings.putString("notifications.result_previews", resultPreviews.toString())
        settings.putString("notifications.live_status", liveStatus.toString())
        settings.putString("notifications.boards", boardIds.filter { it.isNotBlank() }.sorted().joinToString("\n"))
    }

    companion object {
        fun load(settings: DeviceSettings): NotificationSettings {
            fun flag(key: String) = settings.string(key)?.toBooleanStrictOrNull() ?: true
            return NotificationSettings(
                enabled = flag("notifications.enabled"),
                runningChats = flag("notifications.running_chats"),
                successfulChats = flag("notifications.successful_chats"),
                attentionChats = flag("notifications.attention_chats"),
                reviewCards = flag("notifications.review_cards"),
                style = settings.string("notifications.style")?.let { name -> NotificationStyle.entries.firstOrNull { it.name == name } } ?: NotificationStyle.DETAILED,
                resultPreviews = flag("notifications.result_previews"),
                liveStatus = flag("notifications.live_status"),
                boardIds = settings.string("notifications.boards").orEmpty().split('\n').filter { it.isNotBlank() }.toSet(),
            )
        }
    }
}

sealed interface NotificationEvent {
    val cardId: String
    val card: Card

    data class ChatFinished(override val cardId: String, override val card: Card, val resultPreview: String?, val subagents: List<Subagent>) : NotificationEvent
    data class ReadyForReview(override val cardId: String, override val card: Card) : NotificationEvent
}

private fun normalizedRuntime(runtime: String): String = runtime.trim().lowercase().let { if (it == "canceled") "cancelled" else it }

/**
 * Turns state changes into notification events. The first frame and unseen
 * cards only set the baseline, and every frame advances it even while
 * notifications are off, so re-enabling never replays old transitions.
 */
class TransitionTracker {
    private var previous: Map<String, Card>? = null
    private var activities: Map<String, Conversation> = emptyMap()

    fun reset() {
        previous = null
        activities = emptyMap()
    }

    fun update(cards: List<Card>, current: Map<String, Conversation>, settings: NotificationSettings): List<NotificationEvent> {
        val before = previous
        val beforeActivities = activities
        previous = cards.associateBy { it.id }
        activities = current
        before ?: return emptyList()
        val events = mutableListOf<NotificationEvent>()
        for (card in cards) {
            val old = before[card.id] ?: continue
            val chat = Cards.isChat(card)
            if (chat && Runtimes.isActive(old.runtime) && !Runtimes.isActive(card.runtime) && chatResultEnabled(card, settings)) {
                val activity = current[card.id] ?: beforeActivities[card.id]
                val agents = (beforeActivities[card.id] ?: current[card.id])?.subagents.orEmpty()
                events += NotificationEvent.ChatFinished(card.id, card, activity?.let(NotificationContent::resultPreview), agents)
            }
            if (!chat && settings.enabled && settings.reviewCards && card.board_id in settings.boardIds &&
                !Lanes.isReview(old.lane) && Lanes.isReview(card.lane)
            ) {
                events += NotificationEvent.ReadyForReview(card.id, card)
            }
        }
        return events
    }

    companion object {
        private val attention = setOf("failed", "interrupted", "cancelled", "waiting_for_user")

        fun chatResultEnabled(card: Card, settings: NotificationSettings): Boolean {
            if (!settings.enabled) return false
            return if (normalizedRuntime(card.runtime) in attention) settings.attentionChats else settings.successfulChats
        }
    }
}

enum class NotificationRole { CONNECTION, RUNNING, RESULTS }

/** What a notification is about: a running chat, a chat's result, or a card ready for review. */
enum class NotificationKind { RUNNING, RESULT, REVIEW }

enum class NotificationAction(val title: String) { MARK_DONE("Mark done"), OPEN("Open") }

data class NotificationContent(
    /** Unique per notification; platforms use it as the opaque notification tag. */
    val key: String,
    val kind: NotificationKind,
    /** The chat or card the notification opens and acts on. */
    val cardId: String,
    val title: String,
    val text: String,
    val expanded: String? = null,
    val actions: List<NotificationAction> = emptyList(),
    /** For a running chat: the turn it describes. Dismissing hides it until the next turn. */
    val session: String? = null,
) {
    /** The channel: running chats apart from results and reviews. */
    val role: NotificationRole get() = if (kind == NotificationKind.RUNNING) NotificationRole.RUNNING else NotificationRole.RESULTS

    companion object {
        /** The last agent reply, keeping its closing words when long. */
        fun resultPreview(conversation: Conversation): String? {
            val message = conversation.messages.lastOrNull { it.role.equals("assistant", ignoreCase = true) || it.role.equals("agent", ignoreCase = true) } ?: return null
            val text = message.parts.filter { it.type == "text" && it.text.isNotBlank() }.joinToString("\n") { it.text }.trim()
            if (text.isEmpty()) return null
            return if (text.length > 320) "…" + text.takeLast(319).substringAfter(' ').trim() else text
        }

        fun result(event: NotificationEvent.ChatFinished, settings: NotificationSettings): NotificationContent {
            val runtime = normalizedRuntime(event.card.runtime)
            val done = event.subagents.count { it.status.lowercase() in setOf("completed", "failed", "aborted", "cancelled", "canceled") }
            val title = when {
                event.subagents.isNotEmpty() -> "Subagents finished · $done of ${event.subagents.size}"
                runtime == "failed" -> "Chat failed"
                runtime == "interrupted" || runtime == "cancelled" -> "Chat stopped"
                runtime == "waiting_for_user" -> "Chat needs you"
                else -> "Chat finished"
            }
            val text = event.card.title.ifBlank { "Standalone chat" }
            val expanded = event.resultPreview?.takeIf { settings.style == NotificationStyle.DETAILED && settings.resultPreviews && it.isNotBlank() }
            return NotificationContent("result:${event.cardId}", NotificationKind.RESULT, event.cardId, title, text, expanded)
        }

        fun review(event: NotificationEvent.ReadyForReview, boardName: String?, settings: NotificationSettings): NotificationContent {
            val line = "${event.card.title.ifBlank { "Dieter conversation" }} · ${boardName?.ifBlank { null } ?: "Board"}"
            val expanded = event.card.summary.takeIf { settings.style == NotificationStyle.DETAILED && it.isNotBlank() }
            return NotificationContent("review:${event.cardId}", NotificationKind.REVIEW, event.cardId, "Ready for review", line, expanded, listOf(NotificationAction.MARK_DONE, NotificationAction.OPEN))
        }

        fun running(card: Card, detail: String?, activeModels: Int): NotificationContent =
            NotificationContent(
                "$RUNNING_PREFIX${card.id}", NotificationKind.RUNNING, card.id, card.title.ifBlank { "Running chat" }, detail?.ifBlank { null } ?: "Working on your request",
                expanded = "${Counts.of(activeModels, "model")} active now",
                session = session(card),
            )

        /** A running chat's turn: its runtime update, else its last update. */
        fun session(card: Card): String = card.runtime_updated_at.ifBlank { card.updated_at.ifBlank { card.id } }

        /** The card a running chat's notification [key] describes; null for other notifications. */
        fun runningCardId(key: String): String? = key.removePrefix(RUNNING_PREFIX).takeIf { key.startsWith(RUNNING_PREFIX) && it.isNotEmpty() }

        private const val RUNNING_PREFIX = "running:"
    }
}

/** Posts and removes notifications natively; returns false when the platform refused (no permission). */
interface NotificationSink {
    fun post(content: NotificationContent): Boolean
    fun cancel(key: String)
}

enum class SummaryAction { POST, CANCEL, UNCHANGED }

/** The group summary for several results: shown for two or more, removed below that. */
fun resultSummaryAction(activeChildIds: Set<String>, summarizedIds: Set<String>, summaryActive: Boolean): SummaryAction = when {
    activeChildIds.size < 2 && (summaryActive || summarizedIds.isNotEmpty()) -> SummaryAction.CANCEL
    activeChildIds.size < 2 -> SummaryAction.UNCHANGED
    !summaryActive || activeChildIds != summarizedIds -> SummaryAction.POST
    else -> SummaryAction.UNCHANGED
}

/** The wording of the group summary that stacks [count] results and reviews. */
data class ResultSummary(val title: String, val text: String) {
    companion object {
        fun of(count: Int): ResultSummary = ResultSummary(Counts.of(count, "Dieter update"), "Chats finished or cards are ready for review")
    }
}

/** One board in the notification settings' review scope. */
data class NotificationBoardRow(
    val id: String,
    val name: String,
    /** The board's project, and its machine when known: "Dieter · mac-mini". */
    val detail: String,
    val selected: Boolean,
)

/**
 * The notification settings' review scope: every synced board, ordered by
 * project, machine, and board name, and what its controls allow.
 */
data class NotificationBoardScope(
    val rows: List<NotificationBoardRow>,
    /** "2 of 5 synced boards": selected boards that are listed, of all listed. */
    val summary: String,
    /** Review alerts are on, so the board choice applies. */
    val enabled: Boolean,
    val canSelectAll: Boolean,
    val canSelectNone: Boolean,
    /** The choice after selecting all: every listed board added to the current choice. */
    val allBoardIds: Set<String>,
) {
    companion object {
        const val EMPTY = "Boards will appear here after a workspace sync."

        /** [hostnames] maps a project ID to the name of the machine that holds it. */
        fun of(boards: List<Board>, projects: List<Project>, hostnames: Map<String, String>, settings: NotificationSettings): NotificationBoardScope {
            val projectNames = projects.associate { it.id to it.name }
            val listed = boards.distinctBy { it.id }.sortedWith(
                compareBy(
                    { board -> projectNames[board.project_id].orEmpty().lowercase() },
                    { board -> hostnames[board.project_id].orEmpty().lowercase() },
                    { board -> board.name.lowercase() },
                ),
            )
            val ids = listed.mapTo(LinkedHashSet()) { it.id }
            val enabled = settings.enabled && settings.reviewCards
            return NotificationBoardScope(
                rows = listed.map { board ->
                    val project = projectNames[board.project_id]?.takeIf(String::isNotBlank) ?: "Workspace"
                    val host = hostnames[board.project_id]?.takeIf(String::isNotBlank)
                    NotificationBoardRow(board.id, board.name.ifBlank { "Untitled board" }, listOfNotNull(project, host).distinct().joinToString(" · "), board.id in settings.boardIds)
                },
                summary = "${settings.boardIds.count(ids::contains)} of ${Counts.of(ids.size, "synced board")}",
                enabled = enabled,
                canSelectAll = enabled && ids.isNotEmpty(),
                canSelectNone = enabled && settings.boardIds.isNotEmpty(),
                allBoardIds = settings.boardIds + ids,
            )
        }
    }
}

/**
 * Decides what to post for each applied frame: running chats, results, and
 * review requests, suppressing the conversation the user is looking at.
 */
class NotificationPlanner(private val sink: NotificationSink, private val settings: DeviceSettings? = null) {
    private val tracker = TransitionTracker()
    private val posted = HashSet<String>()
    private val fingerprints = HashMap<String, String>()

    /** Card ID → the running session the user dismissed, oldest first; kept across restarts. */
    private val dismissed = LinkedHashMap<String, String>().apply {
        settings?.string(DISMISSED).orEmpty().lineSequence().mapNotNull { line -> line.split(' ').takeIf { it.size == 2 } }.forEach { (cardId, session) -> put(cardId, session) }
    }

    /** The user swiped away a running chat; it stays hidden for the rest of [session]. */
    fun dismissRunning(cardId: String, session: String) {
        if (cardId.isBlank() || session.isBlank() || ' ' in cardId || ' ' in session) return
        dismissed.remove(cardId)
        dismissed[cardId] = session
        while (dismissed.size > MAX_DISMISSED) dismissed.remove(dismissed.keys.first())
        saveDismissals()
        posted -= "running:$cardId"
        fingerprints -= "running:$cardId"
    }

    private fun dismissedSession(cardId: String): String? = dismissed[cardId]

    private fun clearDismissal(cardId: String) {
        if (dismissed.remove(cardId) != null) saveDismissals()
    }

    private fun saveDismissals() {
        settings?.putString(DISMISSED, dismissed.entries.joinToString("\n") { (cardId, session) -> "$cardId $session" }.ifEmpty { null })
    }

    fun reset() {
        tracker.reset()
        posted.clear()
        fingerprints.clear()
    }

    /**
     * Applies one account view. Transitions of cards whose owner was not
     * current before it ([replaying]) only advance the baseline: a machine
     * catching up never replays its backlog as notifications.
     */
    fun frame(
        cards: List<Card>,
        activities: Map<String, Conversation>,
        settings: NotificationSettings,
        boardNames: Map<String, String>,
        runningDetail: (Card) -> String?,
        visibleConversationId: String? = null,
        replaying: (Card) -> Boolean = { false },
    ) {
        val events = tracker.update(cards, activities, settings).filterNot { replaying(it.card) }
        val byId = cards.associateBy { it.id }
        // A dismissal lasts one running session; once the chat stops or leaves, it is over.
        dismissed.keys.filter { id -> byId[id]?.let { Cards.isChat(it) && Runtimes.isActive(it.runtime) } != true }.forEach(::clearDismissal)

        val running = if (settings.enabled && settings.runningChats) {
            cards.filter { Cards.isChat(it) && Runtimes.isActive(it.runtime) && it.id != visibleConversationId }
        } else {
            emptyList()
        }
        val runningKeys = running.mapTo(HashSet()) { "running:${it.id}" }
        for (key in posted.filter { it.startsWith("running:") && it !in runningKeys }) cancel(key)
        for (card in running) {
            val content = NotificationContent.running(card, runningDetail(card), running.size)
            if (dismissedSession(card.id) == content.session) continue
            post(content, fingerprint = "${card.title}|${content.text}|${settings.style}")
        }

        for (key in posted.toList()) {
            val id = key.substringAfter(':')
            val card = byId[id]
            val stale = when {
                key.startsWith("result:") -> card == null || Runtimes.isActive(card.runtime) || !TransitionTracker.chatResultEnabled(card, settings)
                key.startsWith("review:") -> card == null || !Lanes.isReview(card.lane) || card.board_id !in settings.boardIds || !settings.enabled || !settings.reviewCards
                else -> false
            }
            if (stale) cancel(key)
        }

        for (event in events) {
            if (event.cardId == visibleConversationId) continue
            when (event) {
                is NotificationEvent.ChatFinished -> {
                    cancel("running:${event.cardId}")
                    clearDismissal(event.cardId)
                    post(NotificationContent.result(event, settings))
                }
                is NotificationEvent.ReadyForReview -> post(NotificationContent.review(event, boardNames[event.card.board_id], settings))
            }
        }
    }

    private fun post(content: NotificationContent, fingerprint: String? = null) {
        if (fingerprint != null && fingerprints[content.key] == fingerprint && content.key in posted) return
        if (sink.post(content)) {
            posted += content.key
            fingerprint?.let { fingerprints[content.key] = it }
        }
    }

    private fun cancel(key: String) {
        sink.cancel(key)
        posted -= key
        fingerprints -= key
    }

    private companion object {
        const val DISMISSED = "notifications.dismissed"
        const val MAX_DISMISSED = 64
    }
}

/** The background connection's ongoing notification: what the connection does and how much work runs. */
data class BackgroundStatus(
    val title: String,
    val summary: String,
    /** "2 models active now", "Ongoing", or none while not connected. */
    val subtext: String?,
    val connected: Boolean,
    /** Connected, or asleep between Smart checks; otherwise the app should show the connection sheet. */
    val available: Boolean,
    /** Running agents, when live status is shown. */
    val running: Int,
    val boards: Int,
    /** Board cards waiting in review. */
    val reviews: Int,
    /** Subagents the running turns report, when live status is shown. */
    val subagents: Int,
) {
    val boardsLabel: String get() = Counts.of(boards, "board")
    val reviewsLabel: String? get() = reviews.takeIf { it > 0 }?.let { Counts.of(it, "review") }
    val subagentsLabel: String? get() = subagents.takeIf { it > 0 }?.let { Counts.of(it, "subagent") }

    companion object {
        fun of(
            phase: ConnectionPhase,
            error: String?,
            gateway: String?,
            mode: BackgroundMode,
            items: List<Card>,
            boards: Int,
            activeWork: Boolean,
            settings: NotificationSettings,
        ): BackgroundStatus {
            val connected = phase == ConnectionPhase.CONNECTED
            val sleeping = mode == BackgroundMode.PERIODIC && phase == ConnectionPhase.DISCONNECTED
            val name = gateway ?: "Dieter"
            val running = items.count { Runtimes.isActive(it.runtime) }.takeIf { settings.liveStatus } ?: 0
            val subagents = items.sumOf { it.active_subagents.size }.takeIf { settings.liveStatus } ?: 0
            val title = when (phase) {
                ConnectionPhase.CONNECTED -> "Connected to $name"
                ConnectionPhase.RECONNECTING -> "Reconnecting to Dieter"
                ConnectionPhase.AUTH_REQUIRED -> "Sign in to Dieter"
                ConnectionPhase.UPDATE_REQUIRED -> "Update Dieter"
                ConnectionPhase.CONNECTING -> "Connecting to Dieter"
                ConnectionPhase.DISCONNECTED -> if (sleeping) "Dieter Smart sync" else "Connecting to Dieter"
            }
            val summary = when {
                sleeping -> "Sleeping between checks · opens with an immediate refresh"
                connected && mode == BackgroundMode.LIVE -> "$name · live in background"
                connected && activeWork -> "$name · live while work is active"
                connected -> "$name · periodic background check"
                else -> error ?: name
            }
            val subtext = when {
                connected && running > 0 -> "${Counts.of(running, "model")} active now"
                connected -> "Ongoing"
                else -> null
            }
            val reviews = items.count { !Cards.isChat(it) && Lanes.isReview(it.lane) }
            return BackgroundStatus(title, summary, subtext, connected, connected || sleeping, running, boards, reviews, subagents)
        }
    }
}
