package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientFailure
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ProvidersModelTest {
    private fun TestScope.store(core: FakeMobileCore) =
        MobileStore(core, StandardTestDispatcher(testScheduler))

    @Test
    fun theProvidersAreObservedOnlyWhileAViewShowsThem() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            assertFalse(core.observing(Slice.SLICE_PROVIDERS))
            val settings = store.providers.show()
            val inbox = store.providers.show()
            assertTrue(core.observing(Slice.SLICE_PROVIDERS))
            core.publish(
                Slice.SLICE_PROVIDERS,
                update =
                    Update(
                        providers =
                            ProvidersSlice(
                                groups =
                                    listOf(
                                        ProviderGroupRow(
                                            provider = "claude",
                                            provider_name = "Claude",
                                            accounts =
                                                listOf(
                                                    ProviderAccountRow(id = "pa_w", label = "Work")
                                                ),
                                        )
                                    ),
                                summary = ProviderSummary(text = "62% left"),
                            )
                    ),
            )
            runCurrent()
            assertEquals(
                "Work",
                store.providers.slice.value.groups.single().accounts.single().label,
            )
            assertEquals("62% left", store.providers.slice.value.summary?.text)
            settings()
            settings()
            assertTrue(core.observing(Slice.SLICE_PROVIDERS), "the Inbox still shows them")
            inbox()
            assertFalse(core.observing(Slice.SLICE_PROVIDERS))
            assertEquals(
                "Work",
                store.providers.slice.value.groups.single().accounts.single().label,
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun accountAndMachineActionsAreProviderCommands() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            store.providers.rename("pa_w", " Office ")
            store.providers.remove("pa_w")
            store.providers.setDefault("pa_w")
            store.providers.setIncluded("pa_w", false)
            store.providers.submitCode("signin_1", " FIXTURE-CODE ")
            store.providers.submitCallback("signin_1", "http://localhost:1455/cb?code=x")
            store.providers.cancel("signin_1")
            store.providers.dismiss("signin_1")
            store.providers.signOut("pa_w", "box")
            store.providers.check("pa_w", "box")
            store.providers.refreshUsage("pa_w")
            runCurrent()
            assertEquals(
                listOf(
                    ProvidersCommand(rename = ProviderRename("pa_w", "Office")),
                    ProvidersCommand(remove = ProviderAccountRef("pa_w")),
                    ProvidersCommand(set_default = ProviderAccountRef("pa_w")),
                    ProvidersCommand(set_included = ProviderInclusion("pa_w", false)),
                    ProvidersCommand(
                        submit = ProviderSignInInput("signin_1", code = "FIXTURE-CODE")
                    ),
                    ProvidersCommand(
                        submit =
                            ProviderSignInInput(
                                "signin_1",
                                callback_url = "http://localhost:1455/cb?code=x",
                            )
                    ),
                    ProvidersCommand(cancel = ProviderSessionRef("signin_1")),
                    ProvidersCommand(dismiss = ProviderSessionRef("signin_1")),
                    ProvidersCommand(sign_out = ProviderMachineRef("pa_w", "box")),
                    ProvidersCommand(check = ProviderMachineRef("pa_w", "box")),
                    ProvidersCommand(refresh_usage = ProviderAccountRef("pa_w")),
                ),
                core.sentOf { it.providers },
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun resultsCarryTheNewAccountTheSessionAndTheResetOutcome() = runTest {
        val core = FakeMobileCore { command ->
            val providers = command.providers
            when {
                providers?.create != null -> Result(provider_account = ProviderAccountRef("pa_new"))
                providers?.sign_in != null ->
                    Result(provider_sign_in = ProviderSignInStarted("signin_box"))
                providers?.sign_in_all != null ->
                    Result(provider_sign_in = ProviderSignInStarted("signin_all"))
                providers?.consume_reset != null ->
                    Result(
                        provider_reset =
                            ProviderResetOutcome(
                                "pa_p",
                                "reset",
                                "Usage limits were reset.",
                            )
                    )
                else -> Result(done = Done())
            }
        }
        val store = store(core)
        try {
            val created = mutableListOf<String>()
            val sessions = mutableListOf<String>()
            store.providers.create("claude", " Scratch ", "") { created += it }
            store.providers.signIn("pa_new", "box") { sessions += it }
            store.providers.signInAll("pa_new") { sessions += it }
            store.providers.consumeReset("pa_p")
            runCurrent()
            assertEquals(listOf("pa_new"), created)
            assertEquals(listOf("signin_box", "signin_all"), sessions)
            assertEquals("Usage limits were reset.", store.providers.reset.value?.message)
            assertEquals(
                listOf(
                    ProvidersCommand(create = ProviderCreate("claude", "Scratch", "")),
                    ProvidersCommand(sign_in = ProviderSignInStart("pa_new", "box")),
                    ProvidersCommand(sign_in_all = ProviderAccountRef("pa_new")),
                    ProvidersCommand(consume_reset = ProviderAccountRef("pa_p")),
                ),
                core.sentOf { it.providers },
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun aFailedCreateOrSignInReachesItsCallerAndTheStore() = runTest {
        val core = FakeMobileCore {
            throw ClientFailure(Failure(message = "No machine is online; try again when one is."))
        }
        val store = store(core)
        try {
            val failures = mutableListOf<String>()
            var created = false
            var started = false
            store.providers.create("chatgpt", "Personal", "codex", failed = { failures += it }) {
                created = true
            }
            store.providers.signIn("pa_p", "box", failed = { failures += it }) { started = true }
            runCurrent()
            assertFalse(created)
            assertFalse(started)
            assertEquals(List(2) { "No machine is online; try again when one is." }, failures)
            assertEquals("No machine is online; try again when one is.", store.error.value)
        } finally {
            store.close()
        }
    }
}
