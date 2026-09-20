package com.dbpprt.dieter.settings

import org.junit.Assert.*
import org.junit.Test

class NavigationFolderPreferencesTest {
    @Test fun movesHaveOneMembershipAndDeletionOnlyUnfilesItems() {
        val original = NavigationFolderPreferences().adding("Work", "a").adding("Personal", "b")
            .moving("p1", "a").moving("p2", "a").moving("p1", "b")
        assertEquals(listOf("p2"), original.folders[0].itemIDs)
        assertEquals(listOf("p1"), original.folders[1].itemIDs)
        assertEquals(listOf("p3"), original.unfiledIDs(listOf("p1", "p2", "p3")))
        val deleted = original.deleting("b")
        assertEquals(listOf("p1", "p3"), deleted.unfiledIDs(listOf("p1", "p2", "p3")))
        assertEquals(listOf("p1", "p2", "p3"), deleted.moving("p2", null).unfiledIDs(listOf("p1", "p2", "p3")))
        assertEquals(original, original.moving("p1", "missing"))
    }

    @Test fun namesMatchMacCaseAndAccentRulesAndKeepStableIdentity() {
        val original = NavigationFolderPreferences().adding("  Café  ", "a").moving("c1", "a").toggling("a")
        assertEquals("Café", original.folders.single().name)
        assertEquals(original, original.adding("CAFE"))
        assertEquals(original, original.adding("  "))
        val renamed = original.renaming("a", "  Reviews ")
        assertEquals("a", renamed.folders.single().id)
        assertEquals(listOf("c1"), renamed.folders.single().itemIDs)
        assertFalse(renamed.folders.single().isExpanded)
        assertEquals("Reviews", renamed.folders.single().name)
    }

    @Test fun normalizesDuplicateMembershipWithoutPruningTemporarilyMissingResources() {
        val layout = NavigationFolderPreferences.from(listOf(
            NavigationFolder("a", "One", listOf("c1", "c1", "", "offline-chat")),
            NavigationFolder("a", "Duplicate ID", listOf("c2")),
            NavigationFolder("b", "Two", listOf("c1", "c3")),
            NavigationFolder("bad", "  ", listOf("c4")),
        ))
        assertEquals(listOf("a", "b"), layout.folders.map { it.id })
        assertEquals(listOf("c1", "offline-chat"), layout.folders[0].itemIDs)
        assertEquals(listOf("c3"), layout.folders[1].itemIDs)
        assertEquals(listOf("c2", "c4"), layout.unfiledIDs(listOf("c1", "c2", "c3", "c4")))
    }

    @Test fun reordersWithinFolderWithoutChangingOtherMembership() {
        val original = NavigationFolderPreferences().adding("Work", "a").adding("Other", "b")
            .moving("p1", "a").moving("p2", "a").moving("p3", "a").moving("p4", "b")
        val reordered = original.reordering("p1", "p3")
        assertEquals(listOf("p2", "p3", "p1"), reordered.folders[0].itemIDs)
        assertEquals(original.folders[1], reordered.folders[1])
        assertEquals(original, original.reordering("p1", "p4"))
    }
}
