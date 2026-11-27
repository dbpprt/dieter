package com.getdieter.core.memory

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.MemoryDream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Dreams' banners, a conversation's memory switch, and where a project's dreams run. */
class MemoryDreamsTest {
    private val counted =
        MemoryDream(card_id = "c_d", added = 2, merged = 1, retired = 1, verified = 3)

    private fun actions(status: String): List<String> {
        val state = MemoryDreams.state(counted.copy(status = status))
        return listOfNotNull(
            "apply".takeIf { state.can_apply },
            "discard".takeIf { state.can_discard },
            "undo".takeIf { state.can_undo },
        )
    }

    @Test
    fun theActionsFollowTheDreamsStatus() {
        assertEquals(listOf("apply", "discard"), actions("staged"))
        assertEquals(listOf("undo"), actions("applied"))
        for (status in
            listOf("running", "discarded", "undone", "empty", "failed", "new")) assertEquals(
            emptyList(),
            actions(status),
            status,
        )
    }

    @Test
    fun aBannerSaysWhatTheDreamDidAndChanged() {
        val staged = MemoryDreams.state(counted.copy(status = "staged"))
        assertEquals("c_d", staged.card_id)
        assertEquals("Dream awaiting review", staged.title)
        assertEquals("2 added · 1 merged · 1 retired · 3 verified", staged.counts_label)
        assertTrue(staged.detail.isNotEmpty())
        assertFalse(staged.running)
        assertEquals("staged", staged.dream?.status)
        val running = MemoryDreams.state(MemoryDream(card_id = "c_d", status = "running"))
        assertTrue(running.running)
        assertEquals("Dreaming…", running.title)
        assertEquals("", running.counts_label, "nothing to count yet")
        assertEquals(
            "No changes",
            MemoryDreams.state(MemoryDream(status = "empty")).counts_label,
        )
        assertEquals(
            "Dream found nothing to change",
            MemoryDreams.state(MemoryDream(status = "empty")).title,
        )
        assertEquals("Dream applied", MemoryDreams.state(counted.copy(status = "applied")).title)
        assertEquals("Dream undone", MemoryDreams.state(counted.copy(status = "undone")).title)
        assertEquals(
            "Dream discarded",
            MemoryDreams.state(counted.copy(status = "discarded")).title,
        )
        val failed =
            MemoryDreams.state(MemoryDream(status = "failed", error = "the harness is missing"))
        assertEquals("Dream failed", failed.title)
        assertEquals("the harness is missing", failed.error)
        assertEquals("", failed.counts_label)
        assertEquals(
            "The dream did not finish.",
            MemoryDreams.state(MemoryDream(status = "failed")).error,
        )
        assertEquals("", MemoryDreams.state(counted.copy(status = "applied", error = "x")).error)
    }

    private val card = Card(id = "c_1", project_id = "p", scope = "board", memory = true)

    @Test
    fun theSwitchShowsForConversationsOfProjectsWithMemory() {
        val on = MemoryDreams.conversation(card, projectEnabled = true)
        assertTrue(on.enabled && on.shown && on.can_toggle)
        assertFalse(on.dreamer)
        assertNull(on.dream)
        val off = MemoryDreams.conversation(card, projectEnabled = true, enabled = false)
        assertFalse(off.enabled)
        assertTrue(off.can_toggle)
        // Without the project's memory there is no switch.
        val project = MemoryDreams.conversation(card, projectEnabled = false)
        assertFalse(project.shown || project.can_toggle)
        // An archived conversation keeps its setting; one still being created waits.
        assertFalse(MemoryDreams.conversation(card.copy(archived = true), true).can_toggle)
        assertTrue(MemoryDreams.conversation(card.copy(archived = true), true).shown)
        assertFalse(MemoryDreams.conversation(card.copy(id = "local_1"), true).can_toggle)
    }

    @Test
    fun aDreamAlwaysHasMemoryAndShowsItsDreamInstead() {
        val dreamer = card.copy(id = "c_d", memory = false, memory_role = "dreamer")
        val unread = MemoryDreams.conversation(dreamer, projectEnabled = true)
        assertTrue(unread.dreamer && unread.enabled)
        assertFalse(unread.shown || unread.can_toggle)
        assertNull(unread.dream, "unset until its machine reported it")
        val read = MemoryDreams.conversation(dreamer, true, dream = counted.copy(status = "staged"))
        assertEquals("staged", read.dream?.status)
        assertTrue(read.dream!!.can_apply)
        // Another conversation's dream is not this one's.
        assertNull(
            MemoryDreams.conversation(dreamer, true, dream = counted.copy(card_id = "c_x")).dream
        )
        // An ordinary conversation never shows a dream.
        assertNull(
            MemoryDreams.conversation(card, true, dream = counted.copy(card_id = "c_1")).dream
        )
    }

    @Test
    fun aProjectDreamsWhereMostOfItRuns() {
        val owners = mapOf("a" to "studio", "b" to "studio", "c" to "laptop", "d" to "laptop")
        fun cards(vararg ids: String) = ids.map { Card(id = it, project_id = "p") }
        assertEquals(
            "laptop",
            MemoryCalls.busiest(cards("a", "c", "d")) { owners[it.id] },
        )
        // Ties go to the smaller ID, as on the daemons.
        assertEquals("laptop", MemoryCalls.busiest(cards("a", "b", "c", "d")) { owners[it.id] })
        // Dreams do not count.
        val dreams = cards("c", "d").map { it.copy(memory_role = "dreamer") } + cards("a")
        assertEquals("studio", MemoryCalls.busiest(dreams) { owners[it.id] })
        assertNull(MemoryCalls.busiest(emptyList()) { owners[it.id] })
        assertNull(MemoryCalls.busiest(cards("x")) { null })
    }
}
