package com.dbpprt.dieter.ui

import com.dbpprt.dieter.settings.ConversationCreationPreferences
import com.dbpprt.dieter.v1.EffortOption
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.HarnessModel
import org.junit.Assert.assertEquals
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
}
