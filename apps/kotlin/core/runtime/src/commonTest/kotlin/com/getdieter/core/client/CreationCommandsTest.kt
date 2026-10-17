package com.getdieter.core.client

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Checkout
import com.getdieter.api.v1.EffortConfig
import com.getdieter.api.v1.EffortOption
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCapability
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.Lane
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.Project
import com.getdieter.api.v1.ProviderOption
import com.getdieter.client.v1.AgentChoice
import com.getdieter.client.v1.AgentOptionChoice
import com.getdieter.client.v1.CreationCatalogState
import com.getdieter.core.composition.Creation
import com.getdieter.core.composition.CreationDestinations
import com.getdieter.core.composition.CreationInput
import com.getdieter.core.composition.DraftKey
import com.getdieter.core.composition.WorkspaceMode
import com.getdieter.core.conversation.ConversationView
import com.getdieter.core.metadata.MachineMetadata
import com.getdieter.core.selection.AgentControls
import com.getdieter.core.store.WorkspaceView
import com.getdieter.core.v1.CreationPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okio.ByteString.Companion.encodeUtf8
import okio.Path.Companion.toPath

/** Creation, creation previews, and agent pickers as the client contract carries them. */
class CreationCommandsTest {
    private val fast =
        ProviderOption(id = "fast_mode", type = "bool", default_value = "false", mutable = true)
    private val sandbox = ProviderOption(id = "sandbox", type = "text", default_value = "safe")
    private val codex =
        Harness(
            id = "codex",
            name = "Codex",
            default_model = "sol",
            models =
                listOf(
                    HarnessModel(
                        id = "sol",
                        name = "Sol",
                        default_effort = "low",
                        efforts = listOf("low", "high"),
                    ),
                    HarnessModel(id = "spark", name = "Spark"),
                ),
            effort =
                EffortConfig(
                    options = listOf(EffortOption("low", "Low"), EffortOption("high", "High"))
                ),
            capabilities = listOf(HarnessCapability("model-selection", "between-turns")),
            options = listOf(fast, sandbox),
        )
    private val claude =
        Harness(
            id = "claude",
            name = "Claude",
            default_model = "opus",
            models = listOf(HarnessModel(id = "opus", name = "Opus")),
        )
    private val project =
        Project(
            id = "p",
            base_branch = "main",
            checkouts = listOf(Checkout(id = "k1", daemon_id = "d1", name = "Desk")),
        )
    private val board =
        Board(
            id = "b",
            project_id = "p",
            lanes = listOf(Lane("todo", "Todo"), Lane("running", "Running"), Lane("done", "Done")),
        )

    @Test
    fun formChoicesSurviveClosingAndReloadingWithoutSubmission() {
        val storage =
            com.getdieter.core.storage.CoreStorage(
                okio.fakefilesystem.FakeFileSystem(),
                "/creation-test".toPath(),
            )
        val memory =
            com.getdieter.core.composition.CreationMemory(
                storage,
                com.getdieter.core.runtime.SilentLogger,
            )
        val chosen = HarnessSelection("codex", "sol", "high", mapOf("fast_mode" to "true"))
        memory.rememberChoices(
            com.getdieter.client.v1.CreationIntent(
                project_id = "p",
                board_id = "b",
                checkout_id = "k1",
                workspace_mode = "project",
                selection = chosen,
            ),
            false,
        )
        memory.rememberChoices(com.getdieter.client.v1.CreationIntent(), false)
        memory.rememberChoices(
            com.getdieter.client.v1.CreationIntent(project_id = "p", board_id = "other"),
            true,
        )
        val restored =
            com.getdieter.core.composition.CreationMemory(
                storage,
                com.getdieter.core.runtime.SilentLogger,
            )
        assertEquals("p", restored.state.value.project_id)
        assertEquals("b", restored.state.value.boards["p"])
        assertEquals("k1", restored.state.value.checkouts["p"])
        assertEquals(WorkspaceMode.PROJECT, restored.workspaceMode)
        assertEquals("high", restored.selection(listOf(codex))?.effort)
        assertEquals("true", restored.selection(listOf(codex))?.provider_options?.get("fast_mode"))
    }

    @Test
    fun theCreationSliceResolvesEachLoadedProjectsBoardAndCheckout() {
        val many =
            Project(
                id = "p1",
                checkouts =
                    listOf(
                        Checkout(id = "k1", daemon_id = "d1"),
                        Checkout(id = "k2", daemon_id = "d2"),
                    ),
            )
        val single = Project(id = "p2", checkouts = listOf(Checkout(id = "k3", daemon_id = "d3")))
        val view =
            WorkspaceView(
                projects = listOf(many, single),
                boards =
                    mapOf(
                        "p1" to
                            listOf(
                                Board(id = "b1", project_id = "p1"),
                                Board(id = "b2", project_id = "p1"),
                            ),
                        "p2" to emptyList(),
                    ),
            )
        val saved =
            CreationPreferences(
                provider = "codex",
                model = "sol",
                effort = "low",
                workspace_mode = "project",
                project_id = "p1",
                boards = mapOf("p1" to "b2", "unloaded" to "bx"),
                checkouts = mapOf("p1" to "k2"),
            )
        val slice = creationSlice(saved, view, localDaemonId = "d1")
        assertEquals(listOf("project", "p1"), listOf(slice.workspace_mode, slice.project_id))
        assertEquals(
            mapOf("p1" to "b2", "unloaded" to "bx"),
            slice.boards,
            "a project without boards is absent; one not loaded keeps its choice",
        )
        assertEquals(mapOf("p1" to "k2", "p2" to "k3"), slice.checkouts)
        val fresh = creationSlice(CreationPreferences(), view, localDaemonId = "d1")
        assertEquals(mapOf("p1" to "b1"), fresh.boards)
        assertEquals(
            mapOf("p1" to "k1", "p2" to "k3"),
            fresh.checkouts,
            "this device's machine's checkout",
        )
        assertEquals(
            mapOf("p2" to "k3"),
            creationSlice(CreationPreferences(), view, localDaemonId = null).checkouts,
            "several checkouts and no preference: the user chooses",
        )
    }

    @Test
    fun aPreviewShowsThePlanAndTheIntentToSendBack() {
        val input =
            CreationInput(
                project,
                board,
                checkoutId = "k1",
                lane = "todo",
                prompt = "Fix the crash",
                selection = HarnessSelection("codex", "sol", "low"),
                workspaceMode = WorkspaceMode.PROJECT,
                attachments =
                    listOf(
                        MessagePart(
                            type = "file",
                            filename = "log.txt",
                            data_ = "boom".encodeUtf8(),
                        )
                    ),
            )
        val preview =
            creationPreview(
                Creation.plan(
                    input,
                    CreationDestinations(
                        online = setOf("d1"),
                        catalogs = mapOf("d1" to listOf(codex)),
                    ),
                )
            )
        assertEquals("", preview.problem)
        assertEquals(CreationCatalogState.CREATION_CATALOG_STATE_LIVE, preview.catalog)
        val intent = preview.intent!!
        assertEquals(
            listOf("p", "b", "k1", "todo", "Fix the crash", "project"),
            listOf(
                intent.project_id,
                intent.board_id,
                intent.checkout_id,
                intent.lane,
                intent.prompt,
                intent.workspace_mode,
            ),
        )
        assertTrue(intent.attachments.isEmpty(), "attachments stay with the form")
        assertEquals(listOf("todo", "running"), preview.start_lanes.map { it.id })
        assertTrue(preview.defers_start && !preview.opens_after_create)
        assertEquals(
            listOf("Fix the crash", "Desk", "", "d1"),
            listOf(
                preview.title,
                preview.destination_status,
                preview.offline_hint,
                preview.daemon_id,
            ),
        )
        assertEquals("Todo · Project directory · Codex / Sol", preview.summary)
        assertEquals(WorkspaceMode.PROJECT.detail, preview.workspace_detail)
        assertEquals(HarnessSelection("codex", "sol", "low"), preview.agent!!.selection)

        val chat =
            creationPreview(
                Creation.plan(
                    input.copy(chat = true, board = null, lane = ""),
                    CreationDestinations(catalogs = mapOf("d1" to listOf(codex))),
                )
            )
        assertEquals(
            "Loading agent models…",
            chat.problem,
            "an offline machine cannot start a chat",
        )
        assertEquals(CreationCatalogState.CREATION_CATALOG_STATE_CACHED, chat.catalog)
        assertTrue(
            chat.start_lanes.isEmpty() && chat.opens_after_create && chat.offline_hint.isNotEmpty()
        )
    }

    @Test
    fun agentControlsTravelWithWhatMayChange() {
        val state =
            agentControlsState(
                AgentControls(
                    HarnessSelection("codex", "sol", "high", mapOf("fast_mode" to "true")),
                    listOf(codex, claude),
                    locked = true,
                )
            )
        assertTrue(!state.provider_enabled && state.model_enabled && !state.effort_enabled)
        assertEquals(
            listOf("Codex", "Sol", "High"),
            listOf(state.provider_label, state.model_label, state.effort_label),
        )
        assertEquals(
            listOf("codex" to "Codex", "claude" to "Claude"),
            state.providers.map { it.id to it.name },
        )
        assertEquals(
            listOf("sol" to "Sol", "spark" to "Spark"),
            state.models.map { it.id to it.name },
        )
        assertEquals(
            listOf("x" to "x"),
            agentControlsState(AgentControls(HarnessSelection("x"), listOf(Harness(id = "x"))))
                .providers
                .map { it.id to it.name },
            "an unnamed agent shows its ID",
        )
        assertEquals(listOf("low", "high"), state.efforts.map { it.id })
        assertEquals(listOf("fast_mode", "sandbox"), state.options.map { it.id })
        assertEquals(mapOf("fast_mode" to "true", "sandbox" to "safe"), state.option_values)
        assertEquals(mapOf("fast_mode" to true, "sandbox" to false), state.option_enabled)
    }

    @Test
    fun choicesApplyWhereThePickersAllowThem() {
        val open = AgentControls(HarnessSelection("codex", "sol", "low"), listOf(codex, claude))
        assertEquals(
            HarnessSelection("claude", "opus", "default"),
            open.choosing(AgentChoice(provider = "claude")),
        )
        assertEquals("spark", open.choosing(AgentChoice(model = "spark")).model)
        assertEquals("high", open.choosing(AgentChoice(effort = "high")).effort)
        assertEquals(
            "true",
            open
                .choosing(
                    AgentChoice(option = AgentOptionChoice(id = "fast_mode", option_value = "true"))
                )
                .provider_options["fast_mode"],
        )
        for (refused in
            listOf(
                AgentChoice(provider = "gone"),
                AgentChoice(model = "gone"),
                AgentChoice(option = AgentOptionChoice(id = "gone")),
                AgentChoice(),
            )) {
            assertFailsWith<ClientFailure>("$refused") { open.choosing(refused) }
        }
        val started = open.copy(locked = true)
        assertFailsWith<ClientFailure> { started.choosing(AgentChoice(provider = "claude")) }
        assertFailsWith<ClientFailure> { started.choosing(AgentChoice(effort = "high")) }
        assertFailsWith<ClientFailure> {
            started.choosing(
                AgentChoice(option = AgentOptionChoice(id = "sandbox", option_value = "open"))
            )
        }
        assertEquals(
            "spark",
            started.choosing(AgentChoice(model = "spark")).model,
            "the harness lets the model change between turns",
        )
        assertEquals(
            "low",
            started.choosing(AgentChoice(model = "spark")).effort,
            "and keeps the effort, which may not change",
        )
    }

    @Test
    fun theComposerShowsItsChoiceAgainstTheConversationsMachine() {
        val card =
            Card(
                id = "c",
                provider = "codex",
                model = "sol",
                effort = "low",
                initial_prompt_sent_at = "2026-09-30T10:00:00Z",
            )
        val view = ConversationView(cardId = "c", daemonId = "d1", loading = false)
        val machines =
            mapOf("d1" to MachineMetadata(harnesses = HarnessCatalog(harnesses = listOf(codex))))
        val following = composerAgent(view, card, emptyMap(), machines)!!
        assertEquals(
            HarnessSelection(
                "codex",
                "sol",
                "low",
                mapOf("fast_mode" to "false", "sandbox" to "safe"),
            ),
            following.selection,
        )
        assertFalse(following.provider_enabled, "a started conversation keeps its provider")
        val chosen =
            HarnessSelection(
                "codex",
                "spark",
                "low",
                mapOf("sandbox" to "safe", "fast_mode" to "false"),
            )
        assertEquals(
            chosen,
            composerAgent(view, card, mapOf(DraftKey("d1", "c") to chosen), machines)!!.selection,
        )
        assertNull(composerAgent(view.copy(daemonId = null), card, emptyMap(), machines))
        assertNull(composerAgent(view, null, emptyMap(), machines))
        assertFalse(
            composerAgent(view, card, emptyMap(), emptyMap())!!.model_enabled,
            "an unknown harness promises no change mid-conversation",
        )
    }
}
