package com.getdieter.core.providers

import com.getdieter.api.v1.ConsumeProviderUsageResetRequest
import com.getdieter.api.v1.CreateProviderAccountRequest
import com.getdieter.api.v1.ProviderKind
import com.getdieter.api.v1.ProviderLoginMethod
import com.getdieter.client.v1.ProviderAccountRef
import com.getdieter.client.v1.ProviderCreate
import com.getdieter.client.v1.ProviderInclusion
import com.getdieter.client.v1.ProviderMachineRef
import com.getdieter.client.v1.ProviderRename
import com.getdieter.client.v1.ProviderSignInStart
import com.getdieter.client.v1.ProvidersCommand
import com.getdieter.core.providers.ProviderFixtures.CHATGPT_TEAM
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_WORK
import com.getdieter.core.providers.ProviderFixtures.account
import com.getdieter.core.providers.ProviderFixtures.box
import com.getdieter.core.providers.ProviderFixtures.kv
import com.getdieter.core.providers.ProviderFixtures.laptop
import com.getdieter.core.providers.ProviderFixtures.login
import com.getdieter.core.providers.ProviderFixtures.mac
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.SilentLogger
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

class ProviderCommandsTest {
    private val macDaemon = FakeProviderDaemon("mac")
    private val boxDaemon = FakeProviderDaemon("box")
    private val accounts = ProviderAccounts()
    private var accountIds = 0
    private var resetKeys = 0

    init {
        accounts.apply(
            ProviderRecords.decode(
                kv(
                    account(CLAUDE_WORK, "claude", "Work"),
                    account(CHATGPT_TEAM, "chatgpt", "Team"),
                    login(CLAUDE_WORK, "box"),
                    login(CHATGPT_TEAM, "box"),
                    login(CHATGPT_TEAM, "mac", state = ProviderKinds.EXPIRED),
                )
            ),
            listOf(mac, box, laptop),
        )
    }

    private fun TestScope.commands(): ProviderCommands {
        val fleet = FakeProviderFleet(macDaemon, boxDaemon)
        return ProviderCommands(
            accounts,
            ProviderSignIn(accounts, fleet, backgroundScope, SilentLogger),
            fleet,
            newAccountId = { "pa_" + "${++accountIds}".padStart(26, 'a') },
            newResetKey = { "key-${++resetKeys}" },
        )
    }

    private fun unavailable(method: String): suspend (String) -> Unit = {
        if (it == method) throw GrpcException(GrpcStatus.UNAVAILABLE, "machine went away")
    }

    @Test
    fun aRetriedResetReusesItsKeyUntilAMachineAnswers() = runTest {
        val commands = commands()
        val reset = ProvidersCommand(consume_reset = ProviderAccountRef(CHATGPT_TEAM))
        boxDaemon.before = unavailable("ConsumeProviderUsageReset")
        assertFailsWith<GrpcException> { commands.execute(reset) }
        assertEquals("machine went away", accounts.view.value.error)
        assertTrue(accounts.view.value.mutating.isEmpty())
        boxDaemon.before = {}
        boxDaemon.resetOutcome = "nothingToReset"
        val outcome = commands.execute(reset).provider_reset!!
        assertEquals(
            listOf("key-1", "key-1"),
            boxDaemon.attempts.filterIsInstance<ConsumeProviderUsageResetRequest>().map {
                it.idempotency_key
            },
        )
        assertTrue(macDaemon.resets.isEmpty(), "the mac's sign-in expired")
        assertEquals(CHATGPT_TEAM, outcome.account_id)
        assertEquals("nothingToReset", outcome.outcome)
        assertEquals("Nothing to reset: no usage limit is reached.", outcome.message)
        assertNull(accounts.view.value.error)
        commands.execute(reset)
        assertEquals("key-2", boxDaemon.resets.last().idempotency_key, "a new action, a new key")
        assertFailsWith<CoreException> {
            commands.execute(ProvidersCommand(consume_reset = ProviderAccountRef(CLAUDE_WORK)))
        }
    }

    @Test
    fun aRetriedCreateReusesItsAccountId() = runTest {
        val commands = commands()
        val create =
            ProvidersCommand(create = ProviderCreate(provider = "chatgpt", label = " Team 2 "))
        macDaemon.before = unavailable("CreateProviderAccount")
        assertFailsWith<GrpcException> { commands.execute(create) }
        macDaemon.before = {}
        val created = commands.execute(create).provider_account!!
        val first = macDaemon.creates.single()
        assertEquals(
            listOf(first.account_id, first.account_id),
            macDaemon.attempts.filterIsInstance<CreateProviderAccountRequest>().map {
                it.account_id
            },
        )
        assertEquals(first.account_id, created.account_id)
        assertEquals(ProviderKind.PROVIDER_KIND_CHATGPT, first.provider)
        assertEquals(ProviderLoginMethod.PROVIDER_LOGIN_METHOD_CODEX, first.method, "the default")
        assertEquals("Team 2", first.label)
        assertTrue(boxDaemon.creates.isEmpty(), "this device's machine first")
        val next = commands.execute(create).provider_account!!
        assertTrue(next.account_id != created.account_id, "a new action, a new account")

        val siwc = ProviderCreate(provider = "chatgpt", label = "Team", method = "siwc")
        commands.execute(ProvidersCommand(create = siwc))
        assertEquals(
            ProviderLoginMethod.PROVIDER_LOGIN_METHOD_SIWC,
            macDaemon.creates.last().method,
        )
        for (refused in
            listOf(
                ProviderCreate(provider = "claude", label = "Work", method = "codex"),
                ProviderCreate(provider = "claude", label = "Work", method = "host"),
                ProviderCreate(provider = "gemini", label = "Work"),
                ProviderCreate(provider = "claude", label = "  "),
                ProviderCreate(provider = "claude", label = "two\nlines"),
                ProviderCreate(provider = "claude", label = "x".repeat(61)),
            )) {
            val error =
                assertFailsWith<CoreException>("$refused") {
                    commands.execute(ProvidersCommand(create = refused))
                }
            assertEquals(FailureKind.PERMANENT, error.kind)
        }
    }

    @Test
    fun anAccountTakesOneChangeAtATime() = runTest {
        val commands = commands()
        val gate = CompletableDeferred<Unit>()
        macDaemon.before = { if (it == "UpdateProviderAccount") gate.await() }
        val rename = async {
            commands.execute(ProvidersCommand(rename = ProviderRename(CLAUDE_WORK, "Office")))
        }
        runCurrent()
        assertEquals(setOf(CLAUDE_WORK), accounts.view.value.mutating)
        val second =
            assertFailsWith<CoreException> {
                commands.execute(
                    ProvidersCommand(set_included = ProviderInclusion(CLAUDE_WORK, false))
                )
            }
        assertEquals(FailureKind.TRANSIENT, second.kind)
        gate.complete(Unit)
        rename.await()
        assertTrue(accounts.view.value.mutating.isEmpty())
        assertEquals("Office", macDaemon.updates.single().label)
        assertNull(macDaemon.updates.single().include_in_summary)
        commands.execute(ProvidersCommand(set_included = ProviderInclusion(CLAUDE_WORK, false)))
        assertEquals(false, macDaemon.updates.last().include_in_summary)
        assertNull(macDaemon.updates.last().label)
    }

    @Test
    fun machineActionsGoWhereTheyBelong() = runTest {
        val commands = commands()
        commands.execute(ProvidersCommand(sign_out = ProviderMachineRef(CLAUDE_WORK, "box")))
        assertEquals(listOf(CLAUDE_WORK), boxDaemon.signOuts)
        commands.execute(ProvidersCommand(refresh_usage = ProviderAccountRef(CLAUDE_WORK)))
        assertEquals(listOf(CLAUDE_WORK), boxDaemon.refreshes, "where it is signed in")
        commands.execute(ProvidersCommand(remove = ProviderAccountRef(CLAUDE_WORK)))
        assertEquals(listOf(CLAUDE_WORK), macDaemon.deletes)
        val started =
            commands.execute(
                ProvidersCommand(sign_in = ProviderSignInStart(CHATGPT_TEAM, "mac", "device_code"))
            )
        runCurrent()
        val session = accounts.view.value.session(started.provider_sign_in!!.session_id)!!
        assertEquals("mac", session.daemonId)
        assertEquals(1, macDaemon.starts.size)

        accounts.apply(
            ProviderRecords.decode(kv(account(CLAUDE_WORK, "claude", "Work"))),
            listOf(laptop),
        )
        val offline =
            assertFailsWith<CoreException> {
                commands.execute(ProvidersCommand(refresh_usage = ProviderAccountRef(CLAUDE_WORK)))
            }
        assertEquals(FailureKind.TRANSIENT, offline.kind)
        assertFailsWith<CoreException> {
            commands.execute(ProvidersCommand(rename = ProviderRename(CLAUDE_WORK, "Office")))
        }
        assertFailsWith<CoreException> { commands.execute(ProvidersCommand()) }
    }

    @Test
    fun aCreatedAccountShowsAtOnceUntilTheReplicaHasIt() = runTest {
        val commands = commands()
        val records =
            listOf(
                account(CLAUDE_WORK, "claude", "Work"),
                login(CLAUDE_WORK, "box"),
            )
        accounts.apply(ProviderRecords.decode(kv(*records.toTypedArray())), listOf(mac, box))
        val id =
            commands
                .execute(
                    ProvidersCommand(
                        create = ProviderCreate(provider = "claude", label = "Scratch")
                    )
                )
                .provider_account!!
                .account_id
        val pending = accounts.view.value.account(id)!!
        assertTrue(pending.pending)
        assertEquals("Scratch", pending.label)
        assertEquals("claude-code", pending.method)
        assertEquals("mac", accounts.createdOn(id))

        // A sign-in follows at once, on the machine the user chose.
        val started =
            commands.execute(
                ProvidersCommand(sign_in = ProviderSignInStart(id, "box", "paste_code"))
            )
        runCurrent()
        assertEquals(id, boxDaemon.starts.single().account_id)
        assertEquals(
            id,
            accounts.view.value.session(started.provider_sign_in!!.session_id)!!.accountId,
        )
        // Account-wide edits go to the machine that has its record.
        accounts.apply(
            ProviderRecords.decode(kv(*records.toTypedArray())),
            listOf(box, mac.copy(local = false)),
        )
        commands.execute(ProvidersCommand(rename = ProviderRename(id, "Scratch 2")))
        assertEquals(id, macDaemon.updates.single().account_id)

        // The replica's record replaces it.
        accounts.apply(
            ProviderRecords.decode(
                kv(*records.toTypedArray(), account(id, "claude", "Scratch 2"), login(id, "box"))
            ),
            listOf(mac, box),
        )
        val replicated = accounts.view.value.account(id)!!
        assertEquals(false, replicated.pending)
        assertEquals("Scratch 2", replicated.label)
        assertTrue(replicated.signedIn("box"))
        assertNull(accounts.createdOn(id))
        assertEquals(2, accounts.view.value.accounts.size)

        // A tombstone drops one the replica never showed.
        val dropped =
            commands
                .execute(
                    ProvidersCommand(create = ProviderCreate(provider = "chatgpt", label = "Gone"))
                )
                .provider_account!!
                .account_id
        assertTrue(accounts.view.value.account(dropped)!!.pending)
        accounts.apply(
            ProviderRecords.decode(
                kv(
                    *records.toTypedArray(),
                    ProviderFixtures.entry(ProviderRecords.ACCOUNTS, dropped, null, deleted = true),
                )
            ),
            listOf(mac, box),
        )
        assertNull(accounts.view.value.account(dropped))

        // Removing one before the replica showed it hides it at once.
        val removed =
            commands
                .execute(
                    ProvidersCommand(create = ProviderCreate(provider = "claude", label = "Oops"))
                )
                .provider_account!!
                .account_id
        commands.execute(ProvidersCommand(remove = ProviderAccountRef(removed)))
        assertEquals(listOf(removed), macDaemon.deletes)
        assertNull(accounts.view.value.account(removed))
    }
}
