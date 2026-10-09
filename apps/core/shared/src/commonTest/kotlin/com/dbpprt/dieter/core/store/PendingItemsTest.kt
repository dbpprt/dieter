package com.dbpprt.dieter.core.store

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.sync.DirectoryProjection
import kotlin.test.Test
import kotlin.test.assertEquals

class PendingItemsTest {
    private val project = Project(id = "p_1", name = "One")

    @Test
    fun aPendingCardYieldsToItsSyncedCopyBeforeTheCreateReply() {
        val store = WorkspaceStore()
        val local = Card(id = "local_1", project_id = project.id, board_id = "b_1", title = "Exactly once")
        store.setPendingItems(mapOf(local.id to PendingItem(local, "d_1", aliases = setOf("c_expected"))))
        store.applyDirectory(DirectoryProjection(projects = mapOf(project.id to project)), loaded = true)
        assertEquals(listOf("local_1"), store.state.value.allItems.map { it.id })
        assertEquals(setOf("local_1"), store.state.value.pendingCardIds)

        // The account view lists the daemon's deterministic ID while the reply is still in flight.
        val synced = local.copy(id = "c_expected")
        store.applyDirectory(DirectoryProjection(projects = mapOf(project.id to project), cards = mapOf(project.id to listOf(synced))), loaded = true)
        assertEquals(listOf("c_expected"), store.state.value.allItems.map { it.id })
        assertEquals(emptySet(), store.state.value.pendingCardIds)
    }
}
