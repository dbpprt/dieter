package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessCapability
import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.ProviderOption
import com.dbpprt.dieter.client.v1.AgentChoice
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CreationExportsTest {
    private val codex = Harness(
        id = "codex", name = "Codex", default_model = "sol",
        models = listOf(HarnessModel(id = "sol", name = "Sol", default_effort = "low", efforts = listOf("low", "high")), HarnessModel(id = "spark", name = "Spark")),
        capabilities = listOf(HarnessCapability("model-selection", "between-turns")),
        options = listOf(ProviderOption(id = "fast_mode", type = "bool", default_value = "false", mutable = true, models = listOf("sol"))),
    )
    private val claude = Harness(id = "claude", name = "Claude", default_model = "opus", models = listOf(HarnessModel(id = "opus", name = "Opus")))
    private val catalog = HarnessCatalog(harnesses = listOf(codex, claude))

    @Test
    fun aFormStartsFromTheCatalogAndAppliesItsChoices() {
        val fresh = CreationExports.agentControls(HarnessSelection(), catalog, locked = false, choice = AgentChoice())
        assertEquals(HarnessSelection("codex", "sol", "low", mapOf("fast_mode" to "false")), fresh.selection, "a blank provider takes the first agent and its defaults")
        assertTrue(fresh.provider_enabled)
        val chosen = CreationExports.agentControls(fresh.selection!!, catalog, locked = false, choice = AgentChoice(model = "spark"))
        assertEquals(HarnessSelection("codex", "spark", "default"), chosen.selection, "the model's options and default effort")
        assertEquals("Spark", chosen.model_label)
        val edited = CreationExports.agentControls(HarnessSelection("codex", "", "turbo"), catalog, locked = false, choice = AgentChoice())
        assertEquals(HarnessSelection("codex", "sol", "default", mapOf("fast_mode" to "false")), edited.selection, "a chosen agent is validated")
    }

    @Test
    fun aStartedCardIgnoresChoicesItsHarnessDoesNotAllow() {
        val agent = HarnessSelection("codex", "sol", "high", mapOf("fast_mode" to "true"))
        val refused = CreationExports.agentControls(agent, catalog, locked = true, choice = AgentChoice(provider = "claude"))
        assertEquals(agent, refused.selection)
        assertFalse(refused.provider_enabled)
        assertEquals("high", CreationExports.agentControls(agent, catalog, locked = true, choice = AgentChoice(model = "spark")).selection!!.effort, "the effort may not change")
    }

    @Test
    fun workspaceModesReadTheSameInEveryForm() {
        assertEquals("Worktree", CreationExports.workspaceModeTitle("worktree"))
        assertEquals("Worktree", CreationExports.workspaceModeShortTitle("WORKTREE"))
        assertEquals("Create a new isolated Git worktree and branch for this conversation.", CreationExports.workspaceModeDetail("worktree"))
        assertEquals("Project directory", CreationExports.workspaceModeTitle("project"))
        assertEquals("Project", CreationExports.workspaceModeShortTitle(""), "anything but a worktree is the project mode")
        assertEquals("Use the registered project directory on whichever branch it currently has checked out.", CreationExports.workspaceModeDetail("project"))
    }

    @Test
    fun chatsAndStartedTasksOpenOnceCreated() {
        assertTrue(CreationExports.opensAfterCreate(chat = true, lane = ""))
        assertTrue(CreationExports.opensAfterCreate(chat = false, lane = "running"))
        assertFalse(CreationExports.opensAfterCreate(chat = false, lane = "Todo"))
    }
}
