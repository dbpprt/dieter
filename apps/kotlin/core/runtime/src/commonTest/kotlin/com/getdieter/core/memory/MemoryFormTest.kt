package com.getdieter.core.memory

import com.getdieter.api.v1.EffortConfig
import com.getdieter.api.v1.EffortOption
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.MemoryProjectStatus
import com.getdieter.api.v1.MemorySettings
import com.getdieter.api.v1.ProviderOption
import com.getdieter.client.v1.AgentChoice
import com.getdieter.client.v1.AgentOptionChoice
import com.getdieter.client.v1.MachineEntry
import com.getdieter.client.v1.MachineMetadata
import com.getdieter.core.providers.AccountChoice
import com.getdieter.core.providers.AgentAccounts
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant

/** The agent memory setting's form and a project's memory lines. */
class MemoryFormTest {
    private val claude =
        Harness(
            id = "claude-code",
            name = "Claude Code",
            default_model = "opus",
            models =
                listOf(
                    HarnessModel(
                        id = "opus",
                        name = "Opus",
                        default_effort = "high",
                        efforts = listOf("low", "high"),
                    ),
                    HarnessModel(id = "sonnet", name = "Sonnet", default_effort = "low"),
                ),
            effort =
                EffortConfig(
                    options = listOf(EffortOption("low", "Low"), EffortOption("high", "High"))
                ),
            options = listOf(ProviderOption(id = "fast_mode", type = "bool", mutable = true)),
        )
    private val codex =
        Harness(
            id = "codex",
            name = "Codex",
            default_model = "sol",
            models = listOf(HarnessModel(id = "sol", name = "Sol")),
        )
    private val strix = Harness(id = "strix", name = "Strix")
    private val harnesses = listOf(claude, codex)

    /** What GetMemorySettings answers before anyone saved the setting. */
    private val defaults =
        MemorySettings(
            harness = "claude-code",
            model = "opus",
            min_hours = 24,
            min_new_tasks = 5,
            window = "02:00-06:00",
            apply = "auto",
            max_operations = 40,
            max_retire_percent = 25,
            revision = "r1",
        )

    private val accounts =
        AgentAccounts(
            byProvider =
                mapOf(
                    "claude" to
                        listOf(
                            AccountChoice("pa_work", "Work", isDefault = true),
                            AccountChoice("pa_home", "Home"),
                        )
                )
        )

    @Test
    fun picksThisDevicesMachineAndItsDreamingAgents() {
        val machines =
            listOf(
                MachineEntry(id = "far", available = true),
                MachineEntry(id = "here", available = true, local = true),
                MachineEntry(id = "off", local = true),
            )
        assertEquals("here", MemoryForm.machine(machines))
        assertEquals("far", MemoryForm.machine(listOf(machines.last(), machines.first())))
        assertNull(MemoryForm.machine(listOf(MachineEntry(id = "off"))))
        val metadata =
            mapOf("here" to MachineMetadata(harnesses = HarnessCatalog(harnesses + strix)))
        assertEquals(harnesses, MemoryForm.harnesses(metadata, "here"), "Strix cannot dream")
        assertEquals(emptyList(), MemoryForm.harnesses(metadata, "far"))
        assertEquals(emptyList(), MemoryForm.harnesses(metadata, null))
    }

    @Test
    fun unsetFieldsShowTheDaemonsDefaults() {
        val filled = MemoryForm.withDefaults(MemorySettings(revision = "r0"))
        assertEquals("claude-code", filled.harness)
        assertEquals("opus", filled.model)
        assertEquals(24, filled.min_hours)
        assertEquals(5, filled.min_new_tasks)
        assertEquals("auto", filled.apply)
        assertEquals(40, filled.max_operations)
        assertEquals(25, filled.max_retire_percent)
        assertEquals("", filled.window, "an empty window means any time")
        assertEquals("r0", filled.revision)
        assertFalse(filled.dreaming)
        // What someone chose stays; an agent without a model keeps having none.
        val chosen =
            MemorySettings(
                harness = "codex",
                min_hours = 2,
                min_new_tasks = 1,
                window = "22:00-04:00",
                apply = "review",
                max_operations = 3,
                max_retire_percent = 100,
            )
        assertEquals(chosen, MemoryForm.withDefaults(chosen))
        assertEquals(defaults, MemoryForm.withDefaults(defaults))
    }

    @Test
    fun theAgentPickersOfferAgentModelEffortAndAccounts() {
        val agent = MemoryForm.agent(defaults, harnesses, accounts)
        assertEquals(listOf("claude-code", "codex"), agent.providers.map { it.id })
        assertEquals(listOf("Opus", "Sonnet"), agent.models.map { it.name })
        assertEquals("High", agent.effort_label, "the model's default effort")
        assertTrue(agent.options.isEmpty(), "provider options do not apply to dreams")
        assertEquals(listOf("pa_work", "pa_home"), agent.accounts.map { it.id })
        assertEquals("pa_work", agent.selection?.account_id, "the provider default is preselected")
        assertTrue(agent.account_enabled)
        // Codex has no Claude accounts; without accounts there is no account picker.
        assertTrue(
            MemoryForm.agent(defaults.copy(harness = "codex"), harnesses, accounts)
                .accounts
                .isEmpty()
        )
        assertTrue(MemoryForm.agent(defaults, harnesses).accounts.isEmpty())
    }

    @Test
    fun choicesFollowTheAgentsRules() {
        val effort = MemoryForm.choosing(defaults, harnesses, AgentChoice(effort = "low"))
        assertEquals("low", effort.effort)
        val sonnet = MemoryForm.choosing(effort, harnesses, AgentChoice(model = "sonnet"))
        assertEquals("sonnet", sonnet.model)
        assertEquals("low", sonnet.effort, "another model takes its default effort")
        val account =
            MemoryForm.choosing(defaults, harnesses, AgentChoice(account = "pa_home"), accounts)
        assertEquals("pa_home", account.account_id)
        assertEquals(
            defaults,
            MemoryForm.choosing(defaults, harnesses, AgentChoice(account = "pa_gone"), accounts),
            "an account the picker does not offer changes nothing",
        )
        // Another agent takes its default model and forgets the account chosen for the first.
        val switched = MemoryForm.choosing(account, harnesses, AgentChoice(provider = "codex"))
        assertEquals("codex", switched.harness)
        assertEquals("sol", switched.model)
        assertEquals("", switched.account_id)
        assertEquals("r1", switched.revision, "a save checks the revision it was read at")
        assertEquals(
            defaults,
            MemoryForm.choosing(defaults, harnesses, AgentChoice(model = "nope")),
        )
        assertEquals(
            defaults,
            MemoryForm.choosing(
                defaults,
                harnesses,
                AgentChoice(option = AgentOptionChoice("fast_mode", "true")),
            ),
        )
    }

    @Test
    fun theStatusSaysWhetherAndHowDreamsRun() {
        assertEquals("Dreaming off", MemoryForm.status(defaults, harnesses))
        assertEquals(
            "Claude Code · Opus · Apply at once",
            MemoryForm.status(defaults.copy(dreaming = true, configured = true), harnesses),
        )
        // Names the catalog does not know read as IDs.
        assertEquals(
            "mock · mock · Review first",
            MemoryForm.status(
                defaults.copy(dreaming = true, harness = "mock", model = "mock", apply = "review"),
                harnesses,
            ),
        )
        assertEquals("Apply at once", MemoryForm.applyTitle(""))
        assertTrue(MemoryForm.applyDetail("review").contains("apply or discard"))
    }

    @Test
    fun problemsMirrorTheDaemonsBounds() {
        assertNull(MemoryForm.problem(defaults))
        assertNull(MemoryForm.problem(MemorySettings()), "unset fields take the defaults")
        fun refused(settings: MemorySettings) =
            assertNotNull(MemoryForm.problem(settings), "should be refused: $settings")
        refused(defaults.copy(harness = "strix"))
        refused(defaults.copy(model = "op\nus"))
        refused(defaults.copy(account_id = "x".repeat(129)))
        for (hours in listOf(-1, 169)) refused(defaults.copy(min_hours = hours))
        for (hours in listOf(1, 168)) assertNull(
            MemoryForm.problem(defaults.copy(min_hours = hours))
        )
        for (tasks in listOf(-1, 101)) refused(defaults.copy(min_new_tasks = tasks))
        assertNull(MemoryForm.problem(defaults.copy(min_new_tasks = 100)))
        for (changes in listOf(-1, 101)) refused(defaults.copy(max_operations = changes))
        assertNull(MemoryForm.problem(defaults.copy(max_operations = 1)))
        for (percent in listOf(-1, 101)) refused(defaults.copy(max_retire_percent = percent))
        assertNull(MemoryForm.problem(defaults.copy(max_retire_percent = 100)))
        refused(defaults.copy(apply = "sometimes"))
        for (window in listOf("2:00-06:00", "24:00-06:00", "02:00", "02:00-06:60", "any")) refused(
            defaults.copy(window = window)
        )
        for (window in listOf("", "  ", "22:00-04:00", "00:00-23:59")) assertNull(
            MemoryForm.problem(defaults.copy(window = window)),
            window,
        )
        assertNull(MemoryForm.windowProblem(" 02:00-06:00 "))
        assertNotNull(MemoryForm.windowProblem("tonight"))
        // 4 KiB after trimming; multibyte text counts its bytes.
        assertNull(MemoryForm.problem(defaults.copy(instructions = "a".repeat(4096) + "  ")))
        refused(defaults.copy(instructions = "a".repeat(4097)))
        refused(defaults.copy(instructions = "ä".repeat(2049)))
        refused(defaults.copy(instructions = "a\u0000b"))
    }

    @Test
    fun aSaveSendsTrimmedFieldsAndChecksTheRevisionSeparately() {
        val draft =
            defaults.copy(
                dreaming = true,
                harness = " mock ",
                window = " 01:00-05:00 ",
                instructions = "  Keep it short.  ",
                run_on = " d1 ",
                configured = true,
                updated_at = "2026-11-27T10:00:00Z",
            )
        val saved = MemoryForm.saved(draft)
        assertEquals("mock", saved.harness)
        assertEquals("01:00-05:00", saved.window)
        assertEquals("Keep it short.", saved.instructions)
        assertEquals("d1", saved.run_on)
        assertTrue(saved.dreaming)
        // The revision travels as the request's expected revision, not as a stored field.
        assertEquals("", saved.revision)
        assertFalse(saved.configured)
        assertEquals("", saved.updated_at)
    }

    @Test
    fun aDraftIsChangedWhenItWouldSaveSomethingElse() {
        val stored = defaults.copy(configured = true)
        assertFalse(MemoryForm.changed(stored, null), "nothing to save before the first read")
        assertFalse(MemoryForm.changed(stored, stored))
        assertFalse(
            MemoryForm.changed(stored.copy(instructions = "  "), stored),
            "whitespace saves the same",
        )
        assertFalse(
            MemoryForm.changed(stored.copy(revision = "r9"), stored),
            "a newer revision alone is no change",
        )
        assertTrue(MemoryForm.changed(stored.copy(dreaming = true), stored))
        assertTrue(MemoryForm.changed(stored.copy(min_hours = 12), stored))
        // Nobody saved the setting yet: saving the defaults keeps them.
        assertTrue(MemoryForm.changed(defaults, defaults))
    }

    @Test
    fun runOnOffersAutomaticThenTheMachines() {
        val machines =
            listOf(
                MachineEntry(id = "d1", display_name = "Studio"),
                MachineEntry(id = "d2", name = "Laptop"),
            )
        assertEquals(
            listOf("" to "Automatic", "d1" to "Studio", "d2" to "Laptop"),
            MemoryForm.runOnChoices(machines, ""),
        )
        // A machine that left the account stays visible as chosen.
        assertEquals("d9" to "d9", MemoryForm.runOnChoices(machines, "d9").last())
        assertEquals("Studio", MemoryForm.runOnTitle(machines, "d1"))
        assertEquals("Automatic", MemoryForm.runOnTitle(machines, ""))
        assertTrue(MemoryForm.runOnDetail("").contains("most of its conversations"))
    }

    @Test
    fun aProjectsMemoryReadsInTwoLines() {
        val status =
            MemoryProjectStatus(
                project_id = "p",
                enabled = true,
                cards = 12,
                saved = 1,
                backlog = 2,
                last_dream_at = "2026-11-25T10:00:00Z",
                next_dream = "waiting for 3 more finished conversations",
            )
        assertEquals(
            "12 conversations indexed on Studio · 1 saved memory · 2 waiting to be indexed",
            MemoryForm.projectSummary(status, "Studio"),
        )
        assertEquals(
            "1 conversation indexed · 0 saved memories",
            MemoryForm.projectSummary(MemoryProjectStatus(cards = 1), ""),
        )
        val now = Instant.parse("2026-11-27T10:00:00Z").toEpochMilliseconds()
        assertEquals(
            "Last dream 2d ago · Waiting for 3 more finished conversations",
            MemoryForm.projectDreams(status, now),
        )
        assertEquals(
            "No dream yet · Next dream in 5h",
            MemoryForm.projectDreams(
                MemoryProjectStatus(next_dream = "next dream after 2026-11-27T15:30:00Z"),
                now,
            ),
        )
        assertEquals(
            "No dream yet · Dreams run on Studio",
            MemoryForm.projectDreams(MemoryProjectStatus(next_dream = "dreams run on d1"), now) {
                if (it == "d1") "Studio" else it
            },
        )
        assertEquals("No dream yet", MemoryForm.projectDreams(MemoryProjectStatus(), now))
    }
}
