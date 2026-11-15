package com.getdieter.core.providers

import com.getdieter.core.providers.ProviderFixtures.CHATGPT_TEAM
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_HOME
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_WORK
import com.getdieter.core.providers.ProviderFixtures.account
import com.getdieter.core.providers.ProviderFixtures.box
import com.getdieter.core.providers.ProviderFixtures.default
import com.getdieter.core.providers.ProviderFixtures.entry
import com.getdieter.core.providers.ProviderFixtures.kv
import com.getdieter.core.providers.ProviderFixtures.login
import com.getdieter.core.providers.ProviderFixtures.mac
import com.getdieter.core.providers.ProviderFixtures.tokens
import com.getdieter.core.providers.ProviderFixtures.usage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProviderRecordsTest {
    @Test
    fun decodesTheThreeNamespacesTolerantly() {
        val records =
            ProviderRecords.decode(
                kv(
                    account(CLAUDE_WORK, "claude", "Work", email = "alice@corp.com"),
                    // Unknown fields are ignored.
                    entry(
                        ProviderRecords.ACCOUNTS,
                        CHATGPT_TEAM,
                        """{"provider":"chatgpt","label":"Team","method":"siwc",""" +
                            """"siwc":{"clientId":"oaiapp_1"},"future":{"x":1}}""",
                    ),
                    // Unreadable: no known provider, not JSON, an empty value.
                    entry(ProviderRecords.ACCOUNTS, "pa_x", """{"provider":"gemini"}"""),
                    entry(ProviderRecords.ACCOUNTS, "pa_y", "not json"),
                    entry(ProviderRecords.ACCOUNTS, "pa_z", null),
                    // Deleted entries are simply gone.
                    entry(ProviderRecords.ACCOUNTS, CLAUDE_HOME, null, deleted = true),
                    default("claude", CLAUDE_WORK),
                    entry(ProviderRecords.DEFAULTS, "gemini", """{"accountId":"pa_q"}"""),
                    login(
                        CLAUDE_WORK,
                        "box",
                        usage = usage("2026-11-14T11:00:00Z", "five_hour" to 38.0),
                        tokens = tokens(1_200_000, 8_400_000),
                        email = "alice@corp.com",
                    ),
                    entry(ProviderRecords.LOGINS, "no-dot", """{"state":"signed_in"}"""),
                    entry(ProviderRecords.LOGINS, "$CLAUDE_WORK.mac", """{"method":"x"}"""),
                )
            )
        assertEquals(listOf(CLAUDE_WORK, CHATGPT_TEAM).sorted(), records.accounts.map { it.id })
        val team = records.accounts.single { it.id == CHATGPT_TEAM }
        assertEquals("siwc", team.method)
        assertTrue(team.includeInSummary, "inclusion defaults to on")
        assertEquals(
            "alice@corp.com",
            records.accounts.single { it.id == CLAUDE_WORK }.identity.email,
        )
        assertEquals(mapOf("claude" to CLAUDE_WORK), records.defaults)
        val login = records.logins.single()
        assertEquals(CLAUDE_WORK, login.accountId)
        assertEquals("box", login.daemonId)
        assertTrue(login.signedIn)
        assertEquals(38.0, login.usage?.windows?.single()?.usedPercent)
        assertEquals(8_400_000, login.tokens?.sevenDay?.total)
        assertEquals(6, records.skipped, "three accounts, one default and two logins unreadable")
        assertEquals(setOf(CLAUDE_HOME), records.removed, "a tombstone marks the removal")
    }

    @Test
    fun loginsOfMachinesTheAccountNoLongerListsAreDropped() {
        val records =
            ProviderRecords.decode(
                kv(
                    account(CLAUDE_WORK, "claude", "Work"),
                    login(CLAUDE_WORK, "box"),
                    login(CLAUDE_WORK, "gone"),
                )
            )
        val listed = ProvidersView.build(records, listOf(mac, box))
        assertEquals(setOf("box"), listed.account(CLAUDE_WORK)!!.logins.keys)
        // Offline from cache the machine list is unknown, so every login shows.
        val unknown = ProvidersView.build(records, emptyList())
        assertEquals(setOf("box", "gone"), unknown.account(CLAUDE_WORK)!!.logins.keys)
        // A daemon that streams under another machine ID is mapped first.
        val mapped =
            ProvidersView.build(records, listOf(mac, box)) { if (it == "gone") "mac" else it }
        assertEquals(setOf("box", "mac"), mapped.account(CLAUDE_WORK)!!.logins.keys)
    }

    @Test
    fun accountsListClaudeFirstThenByLabel() {
        val view =
            ProviderFixtures.view(
                account(CHATGPT_TEAM, "chatgpt", "Team"),
                account(CLAUDE_WORK, "claude", "Work"),
                account(CLAUDE_HOME, "claude", "home"),
                default("claude", CLAUDE_WORK),
            )
        assertEquals(listOf(CLAUDE_HOME, CLAUDE_WORK, CHATGPT_TEAM), view.accounts.map { it.id })
        assertTrue(view.account(CLAUDE_WORK)!!.isDefault)
        assertFalse(view.account(CLAUDE_HOME)!!.isDefault)
        assertEquals(listOf("mac", "box"), view.machines.map { it.id }, "this device's first")
        assertNull(view.account("pa_missing"))
    }

    @Test
    fun accountIdsAreTheDaemonsKeyFormat() {
        val id = ProviderIds.account()
        assertTrue(ProviderIds.valid(id), id)
        assertFalse(ProviderIds.valid("pa_short"))
        assertFalse(ProviderIds.valid("pa_" + "A".repeat(26)))
    }
}
