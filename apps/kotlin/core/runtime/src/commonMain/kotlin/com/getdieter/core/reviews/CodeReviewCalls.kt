package com.getdieter.core.reviews

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.CodeReview
import com.getdieter.api.v1.ReviewerSettings
import com.getdieter.api.v1.StartCodeReviewRequest
import com.getdieter.api.v1.UpdateReviewerSettingsRequest
import com.getdieter.core.board.BoardOperations
import com.getdieter.core.machines.MachineChoice
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.store.WorkspaceStore

/**
 * The code reviewer's calls. The reviewer setting is one account-wide record every machine of the
 * account replicates, so it is read and saved on the machine the caller names, else this device's
 * machine, else the first reachable one. A conversation's switch and its reviews go to the machine
 * that runs it. Confined to the core dispatcher.
 */
class CodeReviewCalls(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val choice: MachineChoice,
    private val board: BoardOperations,
) {
    /** The machine a settings call goes to: [daemonId], else this device's, else any reachable. */
    fun settingsMachine(daemonId: String): String =
        daemonId.ifEmpty { null }
            ?: choice.local()
            ?: choice.any()
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "No machine is online; try again when one is.",
            )

    /** The reviewer setting, or the defaults (not configured) while nobody saved one. */
    suspend fun settings(daemonId: String): ReviewerSettings =
        sessions.call(settingsMachine(daemonId)) { it.GetReviewerSettings().execute(Unit) }

    /**
     * Saves [settings] when the record still has the revision they were read at
     * ([ReviewerSettings.revision]; empty overwrites). Checked as the daemon checks it first.
     */
    suspend fun updateSettings(daemonId: String, settings: ReviewerSettings): ReviewerSettings {
        ReviewerForm.problem(settings)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        val machine = settingsMachine(daemonId)
        return sessions.call(machine) {
            it.UpdateReviewerSettings()
                .execute(
                    UpdateReviewerSettingsRequest(
                        settings = ReviewerForm.saved(settings),
                        expected_revision = settings.revision,
                    )
                )
        }
    }

    /**
     * Switches [cardId]'s reviewer on its machine; it applies from the conversation's next turn.
     */
    suspend fun setEnabled(cardId: String, enabled: Boolean): Card {
        val card = conversation(cardId)
        if (card.archived)
            throw CoreException(
                FailureKind.PERMANENT,
                "An archived conversation keeps its reviewer.",
            )
        return board.setCodeReview(card.id, enabled)
    }

    /**
     * Starts reviewing [cardId]'s changes on its machine and returns the running review; the
     * transcript shows it from then on. [depth] overrides the setting's when not empty.
     */
    suspend fun start(cardId: String, focus: String, depth: String): CodeReview {
        val card = conversation(cardId)
        if (card.archived)
            throw CoreException(FailureKind.PERMANENT, "Restore the conversation to review it.")
        val trimmed = depth.trim()
        if (trimmed.isNotEmpty() && trimmed !in ReviewerForm.DEPTHS)
            throw CoreException(FailureKind.PERMANENT, "Choose a quick or a thorough review.")
        if (focus.encodeToByteArray().size > MAX_FOCUS_BYTES)
            throw CoreException(FailureKind.PERMANENT, "The review focus is limited to 1 KiB.")
        return sessions.call(owner(card)) {
            it.StartCodeReview()
                .execute(
                    StartCodeReviewRequest(card_id = card.id, focus = focus.trim(), depth = trimmed)
                )
        }
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

    private companion object {
        const val MAX_FOCUS_BYTES = 1024
    }
}
