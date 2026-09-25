package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.CardDetail
import com.dbpprt.dieter.v1.CardStateField
import com.dbpprt.dieter.v1.CardStateVersion
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import org.junit.Assert.assertEquals
import org.junit.Test

class CardStateProjectionTest {
    private fun card(lane: String, runtime: String, placement: Long, summary: Long): Card {
        val value = Card.newBuilder().setId("card").setOwnerDaemonId("owner")
            .setLane(lane).setRuntime(runtime).setOrderKey("key-$placement")
        for ((name, count) in listOf("placement" to placement, "summary" to summary)) {
            val fields = if (name == "placement") Card.newBuilder().setLane(lane).setOrderKey("key-$placement")
                else Card.newBuilder().setRuntime(runtime).setSeenResponseSeq(summary).setResponseSeq(summary)
            value.addStateFields(CardStateField.newBuilder().setName(name).setRevision("$name-$count")
                .addVersions(CardStateVersion.newBuilder().putClock("owner", count).setRank("$count").setValue(fields)))
        }
        return value.build()
    }

    @Test fun delayedCopiesCannotReopenFinishedCards() {
        val running = card("running", "running", 1, 1)
        val review = card("review", "idle", 2, 2)
        val done = card("done", "idle", 3, 3)
        val merged = listOf(done, running, review, running).reduce { previous, incoming -> mergeCardState(incoming, previous) }
        assertEquals("done", merged.lane)
        assertEquals("idle", merged.runtime)
        assertEquals(3L, merged.seenResponseSeq)
        val mixed = mergeCardState(card("done", "running", 3, 1), review)
        assertEquals("done", mixed.lane)
        assertEquals("idle", mixed.runtime)
        assertEquals(merged, sharedItems(listOf(done, running, review), mapOf("card" to running)).single())
    }

    @Test fun concurrentBranchesRemainUntilAResolutionCoversBoth() {
        fun branch(lane: String, actor: String): Card {
            val base = card(lane, "idle", 2, 1).toBuilder()
            val field = base.getStateFields(0).toBuilder()
            field.setVersions(0, field.getVersions(0).toBuilder().clearClock().putClock("owner", 1).putClock(actor, 1).setRank(actor))
            return base.setStateFields(0, field).build()
        }
        val a = branch("review", "a")
        val b = branch("done", "b")
        val ab = mergeCardState(b, a)
        assertEquals(ab.stateFieldsList, mergeCardState(a, b).stateFieldsList)
        assertEquals("done", ab.lane)
        assertEquals("unobserved-join", ab.placementRevision)
        val resolvedField = a.getStateFields(0).toBuilder().setRevision("resolved")
        resolvedField.setVersions(0, resolvedField.getVersions(0).toBuilder().putClock("a", 2).putClock("b", 1))
        val resolved = a.toBuilder().setStateFields(0, resolvedField).build()
        val latest = listOf(ab, resolved, b, a).reduce { previous, incoming -> mergeCardState(incoming, previous) }
        assertEquals("review", latest.lane)
        assertEquals("resolved", latest.placementRevision)
    }

    @Test fun transcriptSequenceAndPlacementAdvanceIndependently() {
        fun snapshot(card: Card, sequence: Long) = ConversationSnapshot.newBuilder()
            .setDetail(CardDetail.newBuilder().setCard(card))
            .setConversation(Conversation.newBuilder().setCardId(card.id).setLastSeq(sequence)).build()
        val done = snapshot(card("done", "idle", 3, 3), 10)
        val delayed = snapshot(card("review", "running", 2, 2), 11)
        for (result in listOf(freshestConversation(done, delayed), freshestConversation(delayed, done))) {
            assertEquals("done", result.detail.card.lane)
            assertEquals("idle", result.detail.card.runtime)
            assertEquals(11L, result.conversation.lastSeq)
        }
    }
}
