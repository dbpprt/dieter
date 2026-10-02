package com.dbpprt.dieter.core.legacy

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LegacyInputsTest {
    private val gateway = "https://gateway.getdieter.com:443"
    private val home = "https://dieter.example.net:8443"

    @Test
    fun macInputsKeepTheAttachedMachineNavigationAndDrafts() {
        val state = LegacyInputs.apple(
            AppleLegacyInput(
                endpointsJson = """[{"name":"Dieter Gateway","host":"gateway.getdieter.com","port":443,"secure":true},
                    {"name":"Home","host":"dieter.example.net","port":8443,"secure":true}]""",
                activeEndpointJson = """{"name":"Studio","host":"gateway.getdieter.com","port":443,"secure":true,"daemonID":"d_attached"}""",
                tokensJson = """{"https:\/\/gateway.getdieter.com:443":"t1"}""",
                iosGateway = null, iosToken = null, iosPreferredMachine = null, pendingCommandsJson = null,
                sharedKvAccount = "github:1", sharedKvDaemon = "", sharedKvJson = """{"entries":{},"pending":[]}""",
                draftsJson = """{"version":1,"drafts":[{"target":{"endpointID":"https:\/\/gateway.getdieter.com:443#d_attached","conversationID":"c_1"},"text":"draft","updatedAt":1.0}]}""",
                quickTaskChoicesJson = null, creationWorkspaceMode = "project", terminalSelections = emptyMap(), notificationsEnabled = true, isIos = false,
            ),
        )
        assertEquals(listOf(gateway, home), state.gateways.map { it.origin })
        assertEquals(gateway, state.activeOrigin)
        assertEquals(mapOf(gateway to "d_attached"), state.preferredMachines)
        assertEquals(mapOf(gateway to "t1"), state.tokens)
        assertEquals(gateway, state.activeNavigation?.origin)
        assertEquals("github:1", state.navigation.single().value.account)
        assertEquals(listOf("c_1" to "d_attached"), state.drafts.map { it.value.conversation_id to it.value.daemon_id })
        assertEquals("project", state.creation?.workspace_mode)
        assertEquals(true, state.notifications?.enabled)
    }

    @Test
    fun iosKeepsItsTokenUnlessTheGatewayWasRelocated() {
        fun ios(address: String) = AppleLegacyInput(
            null, null, null, iosGateway = address, iosToken = "tok", iosPreferredMachine = "d_1", null, null, null, null, null, null, null,
            emptyMap(), null, isIos = true,
        )
        val current = LegacyInputs.apple(ios("https://gateway.getdieter.com"))
        assertEquals(mapOf(gateway to "tok"), current.tokens)
        assertEquals(mapOf(gateway to "d_1"), current.preferredMachines)
        val relocated = LegacyInputs.apple(ios("https://board.dbpprt.com"))
        assertEquals(listOf(gateway), relocated.gateways.map { it.origin })
        assertTrue(relocated.tokens.isEmpty(), "the relocated gateway requires a new sign-in")
        val loopback = LegacyInputs.apple(ios("http://127.0.0.1:4242"))
        assertEquals(mapOf("http://127.0.0.1:4242" to "tok"), loopback.tokens)
        assertEquals(mapOf("http://127.0.0.1:4242" to "d_1"), loopback.preferredMachines)
        assertTrue(LegacyInputs.apple(ios("http://192.168.1.2")).gateways.isEmpty())
    }
}
