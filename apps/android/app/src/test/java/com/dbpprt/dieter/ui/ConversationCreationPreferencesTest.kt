package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ProjectHost
import com.dbpprt.dieter.settings.ConversationCreationPreferences
import com.dbpprt.dieter.v1.EffortOption
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.HarnessModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationCreationPreferencesTest {
    private val codex = Harness.newBuilder()
        .setId("codex")
        .setName("Codex")
        .setDefaultModel("sol")
        .addModels(
            HarnessModel.newBuilder()
                .setId("sol")
                .setName("Sol")
                .setDefaultEffort("low")
                .addEfforts("low")
                .addEfforts("xhigh"),
        )
        .setEffort(
            com.dbpprt.dieter.v1.EffortConfig.newBuilder()
                .addOptions(EffortOption.newBuilder().setId("low").setName("Low"))
                .addOptions(EffortOption.newBuilder().setId("xhigh").setName("Extra high")),
        )
        .build()

    @Test
    fun restoresProviderModelEffortAndProjectWorkspace() {
        val resolved = resolveConversationCreationPreferences(
            ConversationCreationPreferences("codex", "sol", "xhigh", "project"),
            listOf(codex),
        )

        assertEquals(
            ResolvedConversationCreationPreferences("codex", "sol", "xhigh", ConversationWorkspaceMode.PROJECT),
            resolved,
        )
    }

    @Test
    fun staleCatalogValuesFallBackButKeepWorkspaceMode() {
        val resolved = resolveConversationCreationPreferences(
            ConversationCreationPreferences("removed", "retired", "invalid", "project"),
            listOf(codex),
        )

        assertEquals(
            ResolvedConversationCreationPreferences("codex", "sol", "low", ConversationWorkspaceMode.PROJECT),
            resolved,
        )
    }

    @Test
    fun firstRunKeepsTheExistingServerDefaultEffort() {
        val resolved = resolveConversationCreationPreferences(
            ConversationCreationPreferences(),
            listOf(codex),
        )

        assertEquals(
            ResolvedConversationCreationPreferences("codex", "sol", "", ConversationWorkspaceMode.WORKTREE),
            resolved,
        )
    }

    @Test
    fun quickTaskOptimisticTitleUsesFirstStoryLineAndBoundsIt() {
        assertEquals("Add keyboard navigation", optimisticQuickTaskTitle("Add keyboard navigation\nKeep focus visible"))
        val title = optimisticQuickTaskTitle(
            "Make every Kanban lane fully accessible to keyboard users while preserving card ordering and focus",
        )
        assert(title.length <= 80)
        assert(!title.endsWith(" "))
    }

    @Test
    fun catalogMustBelongToTheSelectedProjectsDaemon() {
        val hosts = mapOf(
            "project-a" to ProjectHost("gateway#mac", "mac", "Studio Mac", true),
            "project-b" to ProjectHost("gateway#server", "server", "Build server", true),
        )

        assertTrue(harnessCatalogMatchesProject("project-a", "gateway#mac", hosts))
        assertFalse(harnessCatalogMatchesProject("project-b", "gateway#mac", hosts))
        assertFalse(harnessCatalogMatchesProject("project-b", null, hosts))
    }

    @Test
    fun selectedModelMustExistInTheDestinationCatalog() {
        assertTrue(harnessCatalogSupportsSelection(listOf(codex), "codex", "sol"))
        assertFalse(harnessCatalogSupportsSelection(listOf(codex), "codex", "retired"))
        assertFalse(harnessCatalogSupportsSelection(listOf(codex), "claude", "sol"))
    }
}
