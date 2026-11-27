package com.getdieter.core.client

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.CardDetail
import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.ConversationSnapshot
import com.getdieter.api.v1.MemoryDream
import com.getdieter.api.v1.Project
import com.getdieter.client.v1.ConversationSlice
import com.getdieter.core.conversation.ConversationView
import com.getdieter.core.outbox.OutboxView
import com.getdieter.core.presentation.ConversationPresenter
import com.getdieter.core.store.WorkspaceView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A conversation's agent memory in its slice: the switch and a dream's banner. */
class MemorySliceTest {
    private val card = Card(id = "c_1", scope = "board", project_id = "p", lane = "review")
    private val remembering =
        WorkspaceView(projects = listOf(Project(id = "p", memory_enabled = true)))

    private fun slice(
        card: Card? = this.card,
        workspace: WorkspaceView = remembering,
        dream: MemoryDream? = null,
    ): ConversationSlice {
        val view =
            ConversationView(
                cardId = card?.id ?: "c_1",
                daemonId = "d",
                presented =
                    ConversationSnapshot(
                        detail = card?.let { CardDetail(card = it) },
                        conversation = Conversation(status = "idle"),
                    ),
                loading = false,
            )
        return conversationSlice(
            view,
            ConversationPresenter.presentForClient(
                view,
                OutboxView(),
                workspace,
                emptyMap(),
                dream = dream,
            ),
        )
    }

    @Test
    fun theSwitchFollowsTheProjectAndTheCard() {
        assertNull(slice(card = null).state?.memory, "unknown until the card is")
        val off = slice().state!!.memory!!
        assertTrue(off.shown && off.can_toggle)
        assertFalse(off.enabled)
        assertTrue(slice(card = card.copy(memory = true)).state!!.memory!!.enabled)
        // The board's copy carries a switch in flight before the conversation's own does.
        val switched =
            slice(
                workspace = remembering.copy(cards = mapOf("p" to listOf(card.copy(memory = true))))
            )
        assertTrue(switched.state!!.memory!!.enabled)
        // A project without memory shows no switch.
        val hidden = slice(workspace = WorkspaceView()).state!!.memory!!
        assertFalse(hidden.shown || hidden.can_toggle)
    }

    @Test
    fun aDreamShowsItsDreamOnceItsMachineReportedIt() {
        val dreamer = card.copy(id = "c_d", memory_role = "dreamer", memory = true)
        val waiting = slice(card = dreamer).state!!.memory!!
        assertTrue(waiting.dreamer && waiting.enabled)
        assertFalse(waiting.shown, "a dream has no switch")
        assertNull(waiting.dream)
        val staged =
            slice(
                    card = dreamer,
                    dream = MemoryDream(card_id = "c_d", status = "staged", added = 1),
                )
                .state!!
                .memory!!
                .dream!!
        assertEquals("Dream awaiting review", staged.title)
        assertEquals("1 added", staged.counts_label)
        assertTrue(staged.can_apply && staged.can_discard)
        assertFalse(staged.can_undo)
    }
}
