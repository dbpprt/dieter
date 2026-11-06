package com.getdieter.mobile.store

import com.getdieter.api.v1.HarnessSelection
import com.getdieter.client.v1.*
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class CreationModelTest {
    @Test
    fun rejectedAgentChoiceDoesNotBlockChoosingAnAvailableAgent() = runTest {
        val core = FakeMobileCore { command ->
            val request = command.creation_preview
            if (request == null) Result(done = Done())
            else {
                if (request.choice?.provider == "claude")
                    error("That agent is not available on this machine.")
                val selection =
                    if (request.choice?.provider == "codex") HarnessSelection("codex", "sol")
                    else request.intent?.selection
                Result(
                    creation_preview =
                        CreationPreview(
                            intent = request.intent?.copy(selection = selection),
                            agent =
                                AgentControlsState(
                                    selection = selection,
                                    providers = listOf(AgentPickerItem("codex", "Codex")),
                                    provider_enabled = true,
                                ),
                        )
                )
            }
        }
        val store = MobileStore(core, StandardTestDispatcher(testScheduler))
        try {
            val intent =
                CreationIntent(
                    checkout_id = "node-without-claude",
                    selection = HarnessSelection("claude", "opus"),
                )
            store.creation.update(intent, AgentChoice(provider = "claude"))
            runCurrent()
            assertTrue(store.error.value.contains("not available"))
            assertEquals(
                listOf("codex"),
                store.creation.preview.value.agent!!.providers.map { it.id },
            )

            store.creation.update(intent, AgentChoice(provider = "codex"))
            runCurrent()
            assertEquals("codex", store.creation.intent.value.selection?.provider)
            assertEquals(
                listOf("claude", null, "codex"),
                core.sentOf { it.creation_preview }.map { it.choice?.provider },
            )
            // Later text edits must not replay either picker choice.
            store.creation.update(store.creation.intent.value.copy(prompt = "Fix it"))
            advanceTimeBy(100)
            runCurrent()
            assertNull(core.sentOf { it.creation_preview }.last().choice)
        } finally {
            store.close()
        }
    }

    @Test
    fun aRejectedModelIsNotReplayedBeforeTheNextModelChoice() = runTest {
        val core = FakeMobileCore { command ->
            val request = command.creation_preview
            if (request?.choice?.model == "old-model") error("That model is not available.")
            Result(creation_preview = CreationPreview(intent = request?.intent))
        }
        val store = MobileStore(core, StandardTestDispatcher(testScheduler))
        try {
            val intent = CreationIntent(selection = HarnessSelection("codex", "sol"))
            store.creation.update(intent, AgentChoice(model = "old-model"))
            runCurrent()
            assertTrue(store.error.value.isNotEmpty())
            store.creation.update(intent, AgentChoice(model = "sol"))
            runCurrent()
            assertEquals("", store.error.value)
            assertEquals(
                listOf("old-model", null, "sol"),
                core.sentOf { it.creation_preview }.map { it.choice?.model },
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun changingDestinationDiscardsChoicesFromThePreviousMenu() = runTest {
        val core = FakeMobileCore { command ->
            Result(creation_preview = CreationPreview(intent = command.creation_preview?.intent))
        }
        val store = MobileStore(core, StandardTestDispatcher(testScheduler))
        try {
            val old = CreationIntent(project_id = "project", checkout_id = "claude-node")
            store.creation.update(old)
            runCurrent()
            core.sent.clear()

            store.creation.update(old, AgentChoice(model = "opus"))
            store.creation.update(old.copy(checkout_id = "codex-node"))
            runCurrent()
            val request = core.sentOf { it.creation_preview }.single()
            assertNull(request.choice)
            assertEquals("codex-node", request.intent?.checkout_id)
        } finally {
            store.close()
        }
    }
}
