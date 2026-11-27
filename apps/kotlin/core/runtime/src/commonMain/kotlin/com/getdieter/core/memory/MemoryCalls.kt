package com.getdieter.core.memory

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.GetMemoryStatusRequest
import com.getdieter.api.v1.ListMemoryDreamsRequest
import com.getdieter.api.v1.MemoryDream
import com.getdieter.api.v1.MemoryDreamRef
import com.getdieter.api.v1.MemorySettings
import com.getdieter.api.v1.MemoryStatus
import com.getdieter.api.v1.Project
import com.getdieter.api.v1.StartMemoryDreamRequest
import com.getdieter.api.v1.UpdateMemorySettingsRequest
import com.getdieter.core.api.DaemonApi
import com.getdieter.core.board.BoardOperations
import com.getdieter.core.board.Runtimes
import com.getdieter.core.machines.MachineChoice
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.store.WorkspaceStore
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * Agent memory's calls. The memory setting is one account-wide record every machine replicates, so
 * it is read and saved on the machine the caller names, else this device's, else the first
 * reachable one. A project's memory state and its manual dreams go to the machine that dreams for
 * it by default (the one that runs most of its conversations), else one with the project. A
 * conversation's switch and a dream's record go to the machine that runs the conversation: a dream
 * is kept where it ran. Confined to the core dispatcher.
 */
class MemoryCalls(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val choice: MachineChoice,
    private val board: BoardOperations,
    private val settleDelay: Duration = SETTLE_DELAY,
) {
    private val mutableDreams = MutableStateFlow<Map<String, MemoryDream>>(emptyMap())

    /** Dream conversation ID → its dream as its machine last reported it. */
    val dreams: StateFlow<Map<String, MemoryDream>> = mutableDreams.asStateFlow()

    /** The machine a settings call goes to: [daemonId], else this device's, else any reachable. */
    fun settingsMachine(daemonId: String): String =
        daemonId.ifEmpty { null }
            ?: choice.local()
            ?: choice.any()
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "No machine is online; try again when one is.",
            )

    /** The memory setting, or the defaults (not configured) while nobody saved one. */
    suspend fun settings(daemonId: String): MemorySettings =
        sessions.call(settingsMachine(daemonId)) { it.GetMemorySettings().execute(Unit) }

    /**
     * Saves [settings] when the record still has the revision they were read at
     * ([MemorySettings.revision]; empty overwrites). Checked as the daemon checks it first.
     */
    suspend fun updateSettings(daemonId: String, settings: MemorySettings): MemorySettings {
        MemoryForm.problem(settings)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        val machine = settingsMachine(daemonId)
        return sessions.call(machine) {
            it.UpdateMemorySettings()
                .execute(
                    UpdateMemorySettingsRequest(
                        settings = MemoryForm.saved(settings),
                        expected_revision = settings.revision,
                    )
                )
        }
    }

    /**
     * Switches [cardId]'s memory on its machine; it applies from the conversation's next turn. A
     * dream always has memory, and a project without memory has no switch.
     */
    suspend fun setEnabled(cardId: String, enabled: Boolean): Card {
        val card = conversation(cardId)
        if (card.memory_role == MemoryDreams.DREAMER)
            throw CoreException(FailureKind.PERMANENT, "A dream always has memory.")
        if (card.archived)
            throw CoreException(
                FailureKind.PERMANENT,
                "An archived conversation keeps its memory setting.",
            )
        if (store.state.value.project(card.project_id)?.memory_enabled != true)
            throw CoreException(FailureKind.PERMANENT, NO_PROJECT_MEMORY)
        return board.setMemory(card.id, enabled)
    }

    /** [projectId]'s memory state on the machine that dreams for it, else one with the project. */
    suspend fun status(projectId: String): MemoryStatus {
        val project = project(projectId)
        return sessions.call(projectMachine(project.id)) {
            it.GetMemoryStatus().execute(GetMemoryStatusRequest(project_id = project.id))
        }
    }

    /**
     * Starts a dream of [projectId] now on the machine [status] reads, regardless of the dreaming
     * schedule; returns it running, or failed with the reason. Refused while one is running or
     * awaiting review.
     */
    suspend fun startDream(projectId: String): MemoryDream {
        val project = project(projectId)
        if (!project.memory_enabled) throw CoreException(FailureKind.PERMANENT, NO_PROJECT_MEMORY)
        val dream =
            sessions.call(projectMachine(project.id)) {
                it.StartMemoryDream().execute(StartMemoryDreamRequest(project_id = project.id))
            }
        remember(dream)
        return dream
    }

    /** [cardId]'s dream from the machine that ran it; null when it has no record of one. */
    suspend fun dream(cardId: String): MemoryDream? {
        val card = conversation(cardId)
        val dream =
            sessions
                .call(owner(card)) {
                    it.ListMemoryDreams()
                        .execute(ListMemoryDreamsRequest(project_id = card.project_id))
                }
                .dreams
                .firstOrNull { it.card_id == card.id }
        if (dream != null) remember(dream)
        return dream
    }

    /** Applies [cardId]'s staged dream on its machine; the batch is checked again first. */
    suspend fun apply(cardId: String): MemoryDream =
        action(cardId) { api, ref -> api.ApplyMemoryDream().execute(ref) }

    /** Discards [cardId]'s staged dream on its machine. */
    suspend fun discard(cardId: String): MemoryDream =
        action(cardId) { api, ref -> api.DiscardMemoryDream().execute(ref) }

    /** Restores what [cardId]'s applied dream changed, on its machine. */
    suspend fun undo(cardId: String): MemoryDream =
        action(cardId) { api, ref -> api.UndoMemoryDream().execute(ref) }

    /**
     * Keeps [cardId]'s dream current while its conversation is shown: read when [cards] (the listed
     * card and the conversation's own) show it as a dream, and again when its turn starts or ends.
     * The daemon settles a dream just after the turn's end reaches the card, so a dream still
     * running on an idle card is read again a few times. A machine that does not answer leaves the
     * last report.
     */
    suspend fun follow(cardId: String, cards: Flow<Pair<Card?, Card?>>) {
        cards
            .map { (listed, own) ->
                val card = listed ?: own
                card
                    ?.takeIf {
                        listOfNotNull(listed, own).any { it.memory_role == MemoryDreams.DREAMER }
                    }
                    ?.let { DreamWatch(Runtimes.isActive(it.runtime), it.lane, it.archived) }
            }
            .distinctUntilChanged()
            .collectLatest { watch ->
                watch ?: return@collectLatest
                var attempt = 0
                while (true) {
                    val dream =
                        try {
                            dream(cardId)
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Throwable) {
                            null
                        }
                    val settling = dream?.status == MemoryDreams.RUNNING && !watch.active
                    if (!settling || ++attempt > SETTLE_ATTEMPTS) break
                    delay(settleDelay)
                }
            }
    }

    /**
     * The machine for [projectId]'s memory state and manual dreams: the one that runs most of its
     * conversations when it is reachable (the daemon's default dreaming machine), else a reachable
     * one with the project.
     */
    fun projectMachine(projectId: String): String {
        val busiest =
            busiest(
                store.state.value.allItems.filter { it.project_id == projectId },
                choice::owner,
            )
        return busiest?.takeIf { it in choice.reachable() }
            ?: choice.project(projectId)
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "No machine with this project is reachable.",
            )
    }

    private suspend fun action(
        cardId: String,
        call: suspend (DaemonApi, MemoryDreamRef) -> MemoryDream,
    ): MemoryDream {
        // The machine that ran it says when a conversation is no dream.
        val card = conversation(cardId)
        val dream = sessions.call(owner(card)) { call(it, MemoryDreamRef(card_id = card.id)) }
        remember(dream)
        return dream
    }

    private fun remember(dream: MemoryDream) {
        if (dream.card_id.isEmpty()) return
        mutableDreams.value = mutableDreams.value + (dream.card_id to dream)
    }

    private fun project(projectId: String): Project {
        if (projectId.isBlank()) throw CoreException(FailureKind.PERMANENT, "Choose a project.")
        return store.state.value.project(projectId)
            ?: throw CoreException(FailureKind.PERMANENT, "The project is no longer available.")
    }

    private fun conversation(cardId: String): Card {
        if (cardId.isBlank()) throw CoreException(FailureKind.PERMANENT, "Choose a conversation.")
        val card =
            store.shownItem(cardId)
                ?: throw CoreException(
                    FailureKind.PERMANENT,
                    "The conversation is no longer available.",
                )
        if (!OutboxPolicy.isServerBacked(card.id))
            throw CoreException(
                FailureKind.TRANSIENT,
                "The conversation is still being created; try again in a moment.",
            )
        return card
    }

    private fun owner(card: Card): String =
        choice.owner(card)
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "The conversation's machine is unavailable.",
            )

    private data class DreamWatch(val active: Boolean, val lane: String, val archived: Boolean)

    companion object {
        const val NO_PROJECT_MEMORY = "Turn on agent memory for the project first."

        /** How often and how long a dream that outlives its turn is read again. */
        val SETTLE_DELAY = 2.seconds
        const val SETTLE_ATTEMPTS = 5

        /**
         * The machine that runs most of [cards] (dreams left out), as the daemon picks the dreaming
         * machine: ties go to the smaller ID. Null without any.
         */
        fun busiest(cards: List<Card>, owner: (Card) -> String?): String? =
            cards
                .filter { it.memory_role != MemoryDreams.DREAMER }
                .mapNotNull(owner)
                .groupingBy { it }
                .eachCount()
                .entries
                .sortedWith(compareBy({ -it.value }, { it.key }))
                .firstOrNull()
                ?.key
    }
}
