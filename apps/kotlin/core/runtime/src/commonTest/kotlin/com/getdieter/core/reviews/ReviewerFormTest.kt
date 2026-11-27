package com.getdieter.core.reviews

import com.getdieter.api.v1.EffortConfig
import com.getdieter.api.v1.EffortOption
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.ProviderOption
import com.getdieter.api.v1.ReviewerSettings
import com.getdieter.client.v1.AgentChoice
import com.getdieter.client.v1.AgentOptionChoice
import com.getdieter.client.v1.MachineEntry
import com.getdieter.client.v1.MachineMetadata
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The code reviewer's settings form and the labels of its reviews. */
class ReviewerFormTest {
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
    private val harnesses = listOf(claude, codex)

    private val defaults =
        ReviewerSettings(
            harness = "claude-code",
            model = "opus",
            depth = "quick",
            max_findings = 6,
            max_rounds = 3,
            revision = "r1",
        )

    @Test
    fun picksThisDevicesMachineAndItsCatalog() {
        val machines =
            listOf(
                MachineEntry(id = "far", available = true),
                MachineEntry(id = "here", available = true, local = true),
                MachineEntry(id = "off", local = true),
            )
        assertEquals("here", ReviewerForm.machine(machines))
        // An offline local machine is passed over.
        assertEquals("far", ReviewerForm.machine(listOf(machines.last(), machines.first())))
        assertNull(ReviewerForm.machine(listOf(MachineEntry(id = "off"))))
        val metadata = mapOf("here" to MachineMetadata(harnesses = HarnessCatalog(harnesses)))
        assertEquals(harnesses, ReviewerForm.harnesses(metadata, "here"))
        assertEquals(emptyList(), ReviewerForm.harnesses(metadata, "far"))
        assertEquals(emptyList(), ReviewerForm.harnesses(metadata, null))
    }

    @Test
    fun theAgentPickersOfferAgentModelAndEffortOnly() {
        val agent = ReviewerForm.agent(defaults, harnesses)
        assertEquals(listOf("claude-code", "codex"), agent.providers.map { it.id })
        assertEquals(listOf("Opus", "Sonnet"), agent.models.map { it.name })
        assertEquals("Claude Code", agent.provider_label)
        assertEquals("Opus", agent.model_label)
        assertEquals("High", agent.effort_label, "the model's default effort")
        assertEquals(listOf("default", "low", "high"), agent.effort_choices.map { it.id })
        assertTrue(agent.options.isEmpty(), "provider options do not apply to the reviewer")
        assertTrue(agent.accounts.isEmpty())
    }

    @Test
    fun choicesFollowTheAgentsRules() {
        val effort = ReviewerForm.choosing(defaults, harnesses, AgentChoice(effort = "low"))
        assertEquals("low", effort.effort)
        // Another model takes its default effort.
        val sonnet = ReviewerForm.choosing(effort, harnesses, AgentChoice(model = "sonnet"))
        assertEquals("sonnet", sonnet.model)
        assertEquals("low", sonnet.effort)
        // Another agent takes its default model and forgets the account chosen for the first.
        val switched =
            ReviewerForm.choosing(
                defaults.copy(account_id = "pa_x"),
                harnesses,
                AgentChoice(provider = "codex"),
            )
        assertEquals("codex", switched.harness)
        assertEquals("sol", switched.model)
        assertEquals("", switched.account_id)
        assertEquals("r1", switched.revision, "a save checks the revision it was read at")
        // Choices the pickers do not offer change nothing.
        assertEquals(
            defaults,
            ReviewerForm.choosing(defaults, harnesses, AgentChoice(model = "nope")),
        )
        assertEquals(
            defaults,
            ReviewerForm.choosing(
                defaults,
                harnesses,
                AgentChoice(option = AgentOptionChoice("fast_mode", "true")),
            ),
        )
    }

    @Test
    fun theStatusSaysDefaultsUntilSaved() {
        assertEquals("Defaults", ReviewerForm.status(defaults, harnesses))
        assertEquals(
            "Claude Code · Opus",
            ReviewerForm.status(defaults.copy(configured = true), harnesses),
        )
        assertEquals(
            "pi · m",
            ReviewerForm.status(
                defaults.copy(configured = true, harness = "pi", model = "m"),
                harnesses,
            ),
        )
        assertEquals("Quick", ReviewerForm.depthTitle("quick"))
        assertEquals("Thorough", ReviewerForm.depthTitle("thorough"))
        assertTrue(ReviewerForm.depthDetail("quick").isNotEmpty())
        assertTrue(ReviewerForm.depthDetail("thorough").isNotEmpty())
    }

    @Test
    fun problemsMirrorTheDaemonsBounds() {
        assertNull(ReviewerForm.problem(defaults))
        assertEquals(
            "Choose the reviewer's agent.",
            ReviewerForm.problem(defaults.copy(harness = "")),
        )
        assertTrue(ReviewerForm.problem(defaults.copy(depth = "deep")) != null)
        assertTrue(ReviewerForm.problem(defaults.copy(max_findings = 21)) != null)
        assertTrue(ReviewerForm.problem(defaults.copy(max_rounds = 11)) != null)
        assertTrue(ReviewerForm.problem(defaults.copy(min_confidence = 11)) != null)
        assertTrue(ReviewerForm.problem(defaults.copy(instructions = "x".repeat(4097))) != null)
        val saved =
            ReviewerForm.saved(
                defaults.copy(
                    configured = true,
                    updated_at = "now",
                    instructions = "  Focus on SQL.  ",
                    ignore_globs = listOf(" docs/** ", ""),
                )
            )
        assertEquals("", saved.revision)
        assertEquals("", saved.updated_at)
        assertEquals("Focus on SQL.", saved.instructions)
        assertEquals(listOf("docs/**"), saved.ignore_globs)
    }

    @Test
    fun reviewLabels() {
        assertEquals("42 s", CodeReviews.duration(42_000))
        assertEquals("1 s", CodeReviews.duration(300))
        assertEquals("3 min 12 s", CodeReviews.duration(192_000))
        assertEquals("", CodeReviews.duration(0))
        assertEquals("a.go:7", CodeReviews.location("a.go", 7, 7))
        assertEquals("a.go:7–9", CodeReviews.location("a.go", 7, 9))
        assertEquals("a.go", CodeReviews.location("a.go", 0, 0))
        assertEquals("", CodeReviews.changeLabel(0, 0, 0))
        assertEquals("Medium", CodeReviews.severityLabel("medium"))
        assertEquals("Still open", CodeReviews.statusLabel("open"))
        assertEquals("", CodeReviews.security(" no. "))
        assertEquals("", CodeReviews.triggerLabel(""))
        assertEquals("Round 3", CodeReviews.roundLabel(3, emptyList(), emptyList()))
    }
}
