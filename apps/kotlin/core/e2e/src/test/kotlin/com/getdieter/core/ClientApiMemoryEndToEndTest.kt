package com.getdieter.core

import com.getdieter.api.v1.HarnessSelection
import com.getdieter.client.v1.AdminCommand
import com.getdieter.client.v1.AdminUpdateProject
import com.getdieter.client.v1.Command
import com.getdieter.client.v1.ConversationSlice
import com.getdieter.client.v1.CreateConversation
import com.getdieter.client.v1.CreationIntent
import com.getdieter.client.v1.MemoryCardRef
import com.getdieter.client.v1.MemoryCommand
import com.getdieter.client.v1.MemoryMachine
import com.getdieter.client.v1.MemoryProjectRef
import com.getdieter.client.v1.MemorySettingsUpdate
import com.getdieter.client.v1.MemorySwitch
import com.getdieter.client.v1.Slice
import com.getdieter.core.client.ClientApi
import com.getdieter.core.client.ClientFailure
import com.getdieter.core.client.ClientSubscription
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.SliceFolds
import com.getdieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Agent memory over the real gateway and daemon with the mock harness: the account's memory setting
 * is read and saved compare-and-set, a project's switch gives new conversations memory, a
 * conversation's switch turns it off on its machine, and a dream started now runs as a dream
 * conversation whose banner follows the dream its machine keeps.
 */
class ClientApiMemoryEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    private suspend fun ClientApi.memory(command: MemoryCommand) =
        dispatch(Command(memory = command))

    private fun ClientApi.watch(
        id: String,
        into: MutableStateFlow<ConversationSlice?>,
    ): ClientSubscription =
        observe(Slice.SLICE_CONVERSATION, id) { update ->
            into.value =
                update.conversation
                    ?: update.conversation_delta?.let {
                        SliceFolds.apply(checkNotNull(into.value), it)
                    }
                    ?: error("conversation observation failed: $update")
        }

    @Test
    fun settingsSwitchesAndDreamsGoThroughTheCore() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)

        // Nobody saved a setting yet: the daemon's defaults.
        val defaults = api.memory(MemoryCommand(settings = MemoryMachine())).memory_settings!!
        assertFalse(defaults.configured)
        assertFalse(defaults.dreaming)
        assertEquals("claude-code", defaults.harness)
        assertEquals(24, defaults.min_hours)
        // The mock harness dreams, so no dream leaves the fixture; dreams start only by hand.
        val saved =
            api.memory(
                    MemoryCommand(
                        update_settings =
                            MemorySettingsUpdate(
                                settings =
                                    defaults.copy(
                                        harness = "mock",
                                        model = "mock",
                                        effort = "",
                                        apply = "review",
                                        min_hours = 2,
                                        window = "",
                                        instructions = "  Keep it short.  ",
                                    )
                            )
                    )
                )
                .memory_settings!!
        assertTrue(saved.configured)
        assertEquals("mock", saved.harness)
        assertEquals("review", saved.apply)
        assertEquals(2, saved.min_hours)
        assertEquals("", saved.window, "empty: any time")
        assertEquals("Keep it short.", saved.instructions)
        assertTrue(saved.revision.isNotEmpty())
        val again =
            api.memory(
                    MemoryCommand(
                        update_settings =
                            MemorySettingsUpdate(
                                daemon_id = fixture.daemonId,
                                settings = saved.copy(max_operations = 10),
                            )
                    )
                )
                .memory_settings!!
        assertEquals(10, again.max_operations)
        // A save based on an older read is refused with the daemon's reason.
        val stale = runCatching {
            api.memory(
                MemoryCommand(
                    update_settings = MemorySettingsUpdate(settings = saved.copy(min_hours = 3))
                )
            )
        }
            .exceptionOrNull()
        assertIs<ClientFailure>(stale)
        assertTrue(stale.failure.message.isNotEmpty())
        // A setting the daemon would refuse is refused before any machine is asked.
        val invalid = runCatching {
            api.memory(
                MemoryCommand(
                    update_settings =
                        MemorySettingsUpdate(settings = again.copy(window = "tonight"))
                )
            )
        }
            .exceptionOrNull()
        assertIs<ClientFailure>(invalid)
        val read =
            api.memory(MemoryCommand(settings = MemoryMachine(fixture.daemonId))).memory_settings!!
        assertEquals(again.revision, read.revision)

        // The project's switch shows at once and once its machines have it.
        val project =
            api.dispatch(
                    Command(
                        admin =
                            AdminCommand(
                                update_project =
                                    AdminUpdateProject(
                                        project_id = fixture.projectId,
                                        memory_enabled = true,
                                    )
                            )
                    )
                )
                .project!!
        assertTrue(project.memory_enabled)
        runtime.workspace.state.await(30.seconds, describe = { "project memory on" }) {
            it.project(fixture.projectId)?.memory_enabled == true
        }
        val status =
            api.memory(MemoryCommand(status = MemoryProjectRef(fixture.projectId))).memory_status!!
        val projectStatus = status.projects.single { it.project_id == fixture.projectId }
        assertTrue(projectStatus.enabled)
        assertEquals(fixture.daemonId, status.machine_id)

        // A dream started now runs as a dream conversation on the project's machine.
        val started =
            api.memory(MemoryCommand(start_dream = MemoryProjectRef(fixture.projectId)))
                .memory_dream!!
        assertEquals("", started.error, "dream: $started")
        assertTrue(started.card_id.isNotEmpty())
        val dreamId = started.card_id
        runtime.workspace.state.await(30.seconds, describe = { "dream listed" }) {
            it.card(dreamId) != null
        }
        val dream = MutableStateFlow<ConversationSlice?>(null)
        val dreamWatch = api.watch(dreamId, dream)
        try {
            // The mock agent changes no memories: once its turn ends, the dream is empty.
            val finished =
                dream.await(
                    120.seconds,
                    describe = { "dream: ${dream.value?.state?.memory}" },
                ) {
                    val state = it?.state?.memory?.dream
                    state != null && !state.running
                }!!
            val memory = finished.state!!.memory!!
            assertTrue(memory.dreamer && memory.enabled)
            assertFalse(memory.shown, "a dream has no switch")
            val banner = memory.dream!!
            assertEquals(dreamId, banner.card_id)
            assertEquals("empty", banner.status, "dream: $banner")
            assertEquals("Dream found nothing to change", banner.title)
            assertEquals("No changes", banner.counts_label)
            assertFalse(banner.can_apply || banner.can_discard || banner.can_undo)
            // Read on demand from the machine that ran it.
            val read = api.memory(MemoryCommand(dream = MemoryCardRef(dreamId))).memory_dream!!
            assertEquals("empty", read.status)
            // Nothing to apply or undo; the daemon says why.
            val apply = runCatching {
                api.memory(MemoryCommand(apply_dream = MemoryCardRef(dreamId)))
            }
                .exceptionOrNull()
            assertIs<ClientFailure>(apply)
            val undo = runCatching {
                api.memory(MemoryCommand(undo_dream = MemoryCardRef(dreamId)))
            }
                .exceptionOrNull()
            assertIs<ClientFailure>(undo)
            // Discarding the empty dream closes it, and its banner says so at once.
            val discarded =
                api.memory(MemoryCommand(discard_dream = MemoryCardRef(dreamId))).memory_dream!!
            assertEquals("discarded", discarded.status)
            dream.await(30.seconds, describe = { "discarded: ${dream.value?.state?.memory}" }) {
                it?.state?.memory?.dream?.status == "discarded"
            }
        } finally {
            dreamWatch.close()
        }

        // A new conversation follows the project's memory.
        val created =
            api.dispatch(
                    Command(
                        create_conversation =
                            CreateConversation(
                                intent =
                                    CreationIntent(
                                        project_id = fixture.projectId,
                                        title = "Remembering chat",
                                        prompt = "first",
                                        selection = HarnessSelection("mock", "mock", "low"),
                                        workspace_mode = "project",
                                    ),
                                chat = true,
                            )
                    )
                )
                .card!!
        assertTrue(created.memory, "the optimistic card carries the project's memory")
        val synced =
            runtime.workspace.state.await(30.seconds, describe = { "memory synced" }) { view ->
                view.chats.any {
                    OutboxPolicy.isServerBacked(it.id) &&
                        it.id !in view.pendingCardIds &&
                        it.title == "Remembering chat" &&
                        it.memory
                }
            }
        val id = synced.chats.first { it.title == "Remembering chat" }.id
        val conversation = MutableStateFlow<ConversationSlice?>(null)
        val watch = api.watch(id, conversation)
        try {
            conversation.await(
                60.seconds,
                describe = { "memory on: ${conversation.value?.state}" },
            ) {
                val memory = it?.state?.memory
                memory != null && memory.shown && memory.enabled && memory.can_toggle
            }
            // The switch turns it off on the conversation's machine.
            val off =
                api.memory(MemoryCommand(set_enabled = MemorySwitch(id, enabled = false))).card!!
            assertFalse(off.memory)
            runtime.workspace.state.await(30.seconds, describe = { "memory off" }) { view ->
                view.card(id)?.memory == false && id !in view.pendingCardIds
            }
            conversation.await(30.seconds, describe = { "switch shown" }) {
                it?.state?.memory?.enabled == false
            }
        } finally {
            watch.close()
        }
    }
}
