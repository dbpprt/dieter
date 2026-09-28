package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.HarnessModel
import com.dbpprt.dieter.v1.MessagePart
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class CardCreationDraftTest {
    private val harnesses = listOf(Harness.newBuilder().setId("codex").setDefaultModel("first")
        .addModels(HarnessModel.newBuilder().setId("first"))
        .addModels(HarnessModel.newBuilder().setId("second")).build())
    private val defaults = ResolvedConversationCreationPreferences("codex", "first", "low", ConversationWorkspaceMode.WORKTREE)

    @Test
    fun catalogRefreshAndOptionsRoundTripPreserveEveryEditedField() {
        val draft = CardCreationDraft()
        draft.initialize(defaults, harnesses, "todo")
        draft.prompt = "  First line\nSecond line  "
        draft.quickTaskOpen = true
        draft.openOptions()
        assertEquals("First line", draft.title)
        assertEquals("  First line\nSecond line  ", draft.prompt)
        assertFalse(draft.quickTaskOpen)
        draft.title = "Edited title"
        draft.model = "second"
        draft.effort = "high"
        draft.providerOptions = mapOf("fast_mode" to "true")
        draft.lane = "running"
        draft.workspaceMode = ConversationWorkspaceMode.PROJECT
        draft.labelIds += "label-1"
        val attachment = MessagePart.newBuilder().setType("file").setFilename("draft.txt").build()
        draft.attachments += attachment
        draft.initialize(defaults, emptyList(), "todo")
        draft.initialize(defaults, harnesses.map { it.toBuilder().setName("Refreshed").build() }, "todo")
        draft.openOptions()
        assertEquals("Edited title", draft.title)
        assertEquals("  First line\nSecond line  ", draft.prompt)
        assertEquals(ResolvedConversationCreationPreferences("codex", "second", "high", ConversationWorkspaceMode.PROJECT), draft.preferences())
        assertEquals(mapOf("fast_mode" to "true"), draft.providerOptions)
        assertEquals("running", draft.lane)
        assertEquals(listOf("label-1"), draft.labelIds.toList())
        assertEquals(listOf(attachment), draft.attachments.toList())
    }

    @Test
    fun delayedCatalogInitializesSettingsWithoutTouchingTextAndClearedTitleStaysCleared() {
        val draft = CardCreationDraft()
        draft.prompt = "Written before connection"
        draft.initialize(defaults, emptyList(), "todo")
        draft.openOptions()
        draft.title = ""
        draft.initialize(defaults, harnesses, "todo")
        draft.openOptions()
        assertEquals("", draft.title)
        assertEquals("Written before connection", draft.prompt)
        assertEquals(defaults, draft.preferences())
    }

    @Test
    fun arrivingCatalogDoesNotOverwriteEarlyLaneAndWorkspaceEdits() {
        val draft = CardCreationDraft()
        draft.initialize(defaults, emptyList(), "todo")
        draft.lane = "running"
        draft.workspaceMode = ConversationWorkspaceMode.PROJECT
        draft.initialize(defaults, harnesses, "todo")
        assertEquals("running", draft.lane)
        assertEquals(ConversationWorkspaceMode.PROJECT, draft.workspaceMode)
        assertEquals("codex", draft.provider)
    }

    @Test
    fun returningFromDirectFullEditorDoesNotReseedClearedTitle() {
        val draft = CardCreationDraft()
        draft.markFullEditorOpened()
        draft.prompt = "Only a task body so far"
        draft.title = ""
        draft.openOptions()
        assertEquals("", draft.title)
        assertEquals("Only a task body so far", draft.prompt)
    }

    @Test
    fun explicitAgentChangeResetsOnlyDependentSettings() {
        val draft = CardCreationDraft()
        draft.initialize(defaults, harnesses, "todo")
        draft.prompt = "Keep this"
        draft.providerOptions = mapOf("obsolete" to "true")
        draft.selectModel("second", harnesses)
        assertEquals("second", draft.model)
        assertEquals("", draft.effort)
        assertEquals(emptyMap<String, String>(), draft.providerOptions)
        assertEquals("Keep this", draft.prompt)
    }
}
