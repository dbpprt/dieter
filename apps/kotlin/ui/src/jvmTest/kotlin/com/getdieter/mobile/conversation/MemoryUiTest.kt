@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.conversation

import androidx.compose.ui.test.*
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.MemoryDream
import com.getdieter.api.v1.MemoryProjectStatus
import com.getdieter.api.v1.MemorySettings
import com.getdieter.api.v1.MemoryStatus
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.MobileApp
import com.getdieter.mobile.desktop.DesktopFixture
import com.getdieter.mobile.navigation.MobileRoute
import com.getdieter.mobile.store.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers

/**
 * Agent memory in the shared UI, rendered offscreen: the conversation's switch, a dream's banner
 * and its actions, the creation toggle, a project's memory, and the memory settings.
 */
class MemoryUiTest {
    private fun dream(status: String, canApply: Boolean = false, canUndo: Boolean = false) =
        MemoryDreamState(
            card_id = "ship",
            status = status,
            title = if (canApply) "Dream awaiting review" else "Dream applied",
            counts_label = "2 added · 1 merged",
            detail = if (canApply) "Apply the changes or discard them." else "",
            can_apply = canApply,
            can_discard = canApply,
            can_undo = canUndo,
            dream = MemoryDream(card_id = "ship", status = status, added = 2, merged = 1),
        )

    private fun conversation(memory: ConversationMemory) =
        DesktopFixture.conversation("ship").copy(state = ConversationState(memory = memory))

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

    private fun core() = FakeMobileCore { command ->
        val memory = command.memory
        val preview = command.creation_preview
        when {
            memory?.settings != null -> Result(memory_settings = defaults)
            memory?.update_settings != null ->
                Result(
                    memory_settings =
                        memory.update_settings!!.settings!!.copy(configured = true, revision = "r2")
                )
            memory?.status != null ->
                Result(
                    memory_status =
                        MemoryStatus(
                            machine = "Home mini",
                            projects =
                                listOf(
                                    MemoryProjectStatus(
                                        project_id = "atlas",
                                        enabled = true,
                                        cards = 12,
                                        saved = 4,
                                        next_dream = "dreaming is off",
                                    )
                                ),
                        )
                )
            memory?.start_dream != null ->
                Result(
                    memory_dream =
                        MemoryDreamState(
                            card_id = "c_dream",
                            status = "running",
                            title = "Dreaming…",
                        )
                )
            memory?.apply_dream != null -> Result(memory_dream = dream("applied", canUndo = true))
            preview != null ->
                Result(
                    creation_preview =
                        CreationPreview(
                            intent =
                                (preview.intent ?: CreationIntent()).let {
                                    it.copy(memory = it.memory ?: true)
                                },
                            memory_available = true,
                        )
                )
            else -> Result(done = Done())
        }
    }

    private fun render(block: DesktopComposeUiTest.(MobileStore, FakeMobileCore) -> Unit) =
        runDesktopComposeUiTest(width = 600, height = 1600) {
            val core = core()
            val store = MobileStore(core, Dispatchers.Unconfined)
            DesktopFixture.publish(core)
            setContent { MobileApp(store, desktopHost = false) }
            waitForIdle()
            try {
                block(store, core)
            } finally {
                store.close()
            }
        }

    private fun DesktopComposeUiTest.open(
        store: MobileStore,
        core: FakeMobileCore,
        memory: ConversationMemory,
    ) {
        store.openConversation("ship")
        waitForIdle()
        core.publish(Slice.SLICE_CONVERSATION, "ship", Update(conversation = conversation(memory)))
        waitForIdle()
    }

    @Test
    fun theConversationMenuSwitchesMemory() = render { store, core ->
        open(store, core, ConversationMemory(enabled = true, shown = true, can_toggle = true))
        onNodeWithTag("chrome-conversation-menu").performClick()
        waitForIdle()
        onNodeWithTag("menu-memory-switch").performClick()
        waitForIdle()
        assertEquals(
            listOf(MemorySwitch(card_id = "ship", enabled = false)),
            core.sentOf { it.memory?.set_enabled },
        )
    }

    @Test
    fun aProjectWithoutMemoryShowsNoSwitch() = render { store, core ->
        open(store, core, ConversationMemory(shown = false))
        onNodeWithTag("chrome-conversation-menu").performClick()
        waitForIdle()
        onAllNodesWithTag("menu-memory-switch").assertCountEquals(0)
        onAllNodesWithTag("memory-dream").assertCountEquals(0)
    }

    @Test
    fun aDreamShowsWhatItChangedAndItsActions() = render { store, core ->
        open(
            store,
            core,
            ConversationMemory(
                enabled = true,
                dreamer = true,
                dream = dream("staged", canApply = true),
            ),
        )
        onNodeWithTag("memory-dream").assertIsDisplayed()
        onNodeWithText("Dream awaiting review").assertIsDisplayed()
        onNodeWithText("2 added · 1 merged", substring = true).assertIsDisplayed()
        onNodeWithText("Discard").performClick()
        waitForIdle()
        assertEquals(listOf("ship"), core.sentOf { it.memory?.discard_dream }.map { it.card_id })
        onNodeWithText("Apply").performClick()
        waitForIdle()
        assertEquals(listOf("ship"), core.sentOf { it.memory?.apply_dream }.map { it.card_id })

        // Once applied, Undo restores it.
        core.publish(
            Slice.SLICE_CONVERSATION,
            "ship",
            Update(
                conversation =
                    conversation(
                        ConversationMemory(
                            enabled = true,
                            dreamer = true,
                            dream = dream("applied", canUndo = true),
                        )
                    )
            ),
        )
        waitForIdle()
        onNodeWithText("Dream applied").assertIsDisplayed()
        onAllNodesWithText("Apply").assertCountEquals(0)
        onNodeWithText("Undo").performClick()
        waitForIdle()
        assertEquals(listOf("ship"), core.sentOf { it.memory?.undo_dream }.map { it.card_id })
        // A dream always has memory: no switch.
        onNodeWithTag("chrome-conversation-menu").performClick()
        waitForIdle()
        onAllNodesWithTag("menu-memory-switch").assertCountEquals(0)
    }

    @Test
    fun aNewConversationFollowsTheProjectsMemory() = render { store, _ ->
        store.newConversation()
        // The core's preview, which says the project has memory, arrives after typing settles.
        waitUntil(timeoutMillis = 5_000) { store.creation.preview.value.memory_available }
        waitForIdle()
        onNodeWithTag("creation-form").performScrollToNode(hasTestTag("creation-memory"))
        onNodeWithText("The agent recalls and saves what this project learned").assertIsDisplayed()
        assertEquals(true, store.creation.intent.value.memory, "on, as the project")
        onNodeWithTag("creation-memory").performClick()
        waitForIdle()
        assertEquals(false, store.creation.intent.value.memory)
    }

    @Test
    fun aProjectTurnsMemoryOnAndStartsADream() = render { store, core ->
        val atlas = DesktopFixture.atlas.copy(memory_enabled = true)
        core.publish(
            Slice.SLICE_WORKSPACE,
            update =
                Update(
                    workspace =
                        DesktopFixture.workspace.copy(
                            projects = listOf(atlas, DesktopFixture.homelab)
                        )
                ),
        )
        store.push(MobileRoute.Project("atlas"))
        waitForIdle()
        onNodeWithTag("chrome-project-menu").performClick()
        waitForIdle()
        onNodeWithTag("menu-project-edit").performClick()
        waitForIdle()
        onNodeWithTag("project-memory-status", useUnmergedTree = true)
            .performScrollTo()
            .assertTextContains("12 conversations indexed on Home mini · 4 saved memories", true)
        assertEquals(listOf("atlas"), core.sentOf { it.memory?.status }.map { it.project_id })
        onNodeWithTag("project-memory-dream").performScrollTo().performClick()
        waitForIdle()
        assertEquals(listOf("atlas"), core.sentOf { it.memory?.start_dream }.map { it.project_id })
        onNodeWithTag("project-memory-open-dream").performScrollTo().assertIsDisplayed()
        // The switch saves with the project; an unchanged one is left out.
        onNodeWithTag("project-memory").performScrollTo().performClick()
        waitForIdle()
        onNodeWithTag("sheet-save-project").performClick()
        waitForIdle()
        val update = core.sentOf { it.admin?.update_project }.single()
        assertEquals(false, update.memory_enabled)
    }

    @Test
    fun theMemorySettingsSaveWhatWasRead() = render { store, core ->
        store.push(MobileRoute.AgentMemory)
        waitForIdle()
        core.publish(
            Slice.SLICE_METADATA,
            update =
                Update(
                    metadata =
                        MetadataSlice(
                            machines =
                                mapOf(
                                    "mini" to
                                        MachineMetadata(
                                            harnesses =
                                                HarnessCatalog(
                                                    listOf(
                                                        Harness(
                                                            id = "claude-code",
                                                            name = "Claude Code",
                                                            default_model = "opus",
                                                            models =
                                                                listOf(
                                                                    HarnessModel(
                                                                        id = "opus",
                                                                        name = "Opus",
                                                                    ),
                                                                    HarnessModel(
                                                                        id = "sonnet",
                                                                        name = "Sonnet",
                                                                    ),
                                                                ),
                                                        ),
                                                        Harness(id = "strix", name = "Strix"),
                                                    )
                                                ),
                                            loaded = true,
                                        )
                                )
                        )
                ),
        )
        waitForIdle()
        onNodeWithTag("memory-settings").assertIsDisplayed()
        onAllNodesWithText("Dreaming off").onFirst().assertExists()
        onNodeWithTag("picker-model").assertIsDisplayed()
        onNodeWithText("Opus").assertIsDisplayed()
        // Nothing changed and nobody saved yet: saving keeps the defaults.
        onNodeWithTag("memory-settings").performScrollToNode(hasTestTag("memory-save"))
        onNodeWithTag("memory-save").assertIsEnabled()
        onNodeWithTag("memory-settings").performScrollToNode(hasTestTag("memory-dreaming"))
        onNodeWithTag("memory-dreaming").performClick()
        onNodeWithTag("memory-apply-1").performClick()
        onNodeWithText(
                "A dream waits in its conversation until you apply or discard it.",
                useUnmergedTree = true,
            )
            .assertIsDisplayed()
        onNodeWithTag("memory-settings").performScrollToNode(hasTestTag("memory-hours"))
        onNodeWithTag("memory-hours-minus").performClick()
        onNodeWithTag("memory-hours-value", useUnmergedTree = true).assertTextEquals("23")
        // A window the daemon would refuse blocks saving and says why.
        onNodeWithTag("memory-settings").performScrollToNode(hasTestTag("memory-window"))
        onNodeWithTag("memory-window").performTextReplacement("tonight")
        waitForIdle()
        onNodeWithTag("memory-settings").performScrollToNode(hasTestTag("memory-save"))
        onNodeWithTag("memory-save").assertIsNotEnabled()
        onNodeWithTag("memory-settings").performScrollToNode(hasTestTag("memory-window"))
        onNodeWithTag("memory-window").performTextReplacement("")
        waitForIdle()
        onNodeWithTag("memory-settings").performScrollToNode(hasTestTag("memory-save"))
        onNodeWithTag("memory-save").performClick()
        waitForIdle()
        val saved = core.sentOf { it.memory?.update_settings }.single()
        assertEquals("mini", saved.daemon_id)
        val settings = saved.settings!!
        assertTrue(settings.dreaming)
        assertEquals("review", settings.apply)
        assertEquals(23, settings.min_hours)
        assertEquals("", settings.window, "empty: any time")
        assertEquals("r1", settings.revision, "a save checks the revision it read")
        assertEquals(listOf("mini"), core.sentOf { it.memory?.settings }.map { it.daemon_id })
        // The saved setting is the form's new baseline.
        assertEquals("r2", store.memory.settings.value?.revision)
        assertEquals("", store.memory.settings.value?.window)
        assertEquals("", store.memory.problem.value)
    }
}
