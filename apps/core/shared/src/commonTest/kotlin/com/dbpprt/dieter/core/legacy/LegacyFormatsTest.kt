package com.dbpprt.dieter.core.legacy

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.KVEntry
import com.dbpprt.dieter.api.v1.SendMessageRequest
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.journal.OutboxKind
import com.dbpprt.dieter.core.journal.OutboxPlacement
import com.dbpprt.dieter.core.journal.OutboxState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

class LegacyFormatsTest {
    private val gateway = "https://gateway.getdieter.com:443"
    private val create = CreateConversationRequest(project_id = "p_1", title = "t", client_id = "mac_1", command_id = "cmd-1")
    private val createBase64 = CreateConversationRequest.ADAPTER.encodeByteString(create).base64()
    private val sendBase64 = SendMessageRequest.ADAPTER.encodeByteString(SendMessageRequest(card_id = "local_cmd1")).base64()

    @Test
    fun gatewaysMigrateDeduplicateAndDropRemotePlaintext() {
        val gateways = LegacyFormats.gateways(
            listOf(
                Gateway("Dieter Gateway", "board.dbpprt.com", 443, secure = true),
                Gateway("Again", "gateway.getdieter.com", 443, secure = true),
                Gateway("Home", "dieter.example.net", 8443, secure = true),
                Gateway("LAN", "192.168.1.4", 4242, secure = false),
                Gateway("Local", "127.0.0.1", 4242, secure = false),
            ),
        )
        assertEquals(listOf(gateway, "https://dieter.example.net:8443", "http://127.0.0.1:4242"), gateways.map { it.origin })
        assertEquals(gateway to "d_1", LegacyFormats.splitEndpoint("$gateway#d_1", null))
        assertEquals(gateway to "d_2", LegacyFormats.splitEndpoint("d_2", gateway), "a bare daemon ID belongs to the active gateway")
        assertNull(LegacyFormats.splitEndpoint("d_2", null), "a bare daemon ID needs an active gateway")
    }

    @Test
    fun sharedKvCachesCarryEntriesAndEveryIntentShape() {
        val entry = KVEntry(key = "projects-order.p_1.position", value_json = "{}".encodeUtf8())
        val pinnedKey = "pinned-order.c_9.position" // gitleaks:allow -- a navigation key in a test fixture, not a secret
        val cache = LegacyFormats.macSharedKv(
            """{"entries":{"projects-order.p_1.position":"${KVEntry.ADAPTER.encodeByteString(entry).base64()}"},
               "pending":[{"id":"i1","key":"chats-section.p_1.expanded","value":"${"false".encodeUtf8().base64()}","requiresExisting":false},
                          {"id":"i2","key":"$pinnedKey","deleted":true},
                          {"id":"i3","key":"projects-order.p_2.position","parent":"","after":"projects-order.p_1.position","before":"","prepared":"AAE=","daemonID":"d_1"}]}""",
            account = "github:1", daemonId = "d_2",
        )!!
        assertEquals(listOf(entry), cache.entries)
        assertEquals("false".encodeUtf8(), cache.pending[0].put?.value_json)
        assertNotNull(cache.pending[1].delete)
        assertEquals("projects-order.p_1.position", cache.pending[2].move?.after)
        assertEquals(byteArrayOf(0, 1).toByteString(), cache.pending[2].prepared)
        assertEquals("d_1", cache.pending[2].daemon_id)
        assertEquals("d_7", LegacyFormats.macSharedKv("""{"entries":{},"pending":[]}""", account = "local", daemonId = "d_7")!!.daemon_id)

        val mac = LegacyFormats.macSharedKv(
            """{"entries":{},"pending":[{"id":"8C1F","key":"chats-folder.F1.name","value":"${"\"Work\"".encodeUtf8().base64()}","deleted":false,"after":"","before":"","requiresExisting":true,"daemonID":"d_2"}]}""",
            account = "github:1", daemonId = "d_2",
        )!!
        assertEquals("\"Work\"".encodeUtf8(), mac.pending.single().put?.value_json)
        assertTrue(mac.pending.single().put!!.requires_existing)
        assertEquals("", mac.daemon_id, "only the local account is per machine")
        assertEquals(64 + 5, LegacyFormats.macSharedKvFile("github:1", "").length)
    }

    @Test
    fun draftsKeepTheirMachineAndTime() {
        val mac = LegacyFormats.macDrafts(
            """{"version":1,"drafts":[{"target":{"endpointID":"https:\/\/gateway.getdieter.com:443#d_1","projectID":"","conversationID":"c_1","checkoutID":""},"text":"draft","updatedAt":780912345.25}]}""",
        ).single()
        assertEquals(gateway, mac.origin)
        assertEquals("d_1", mac.value.daemon_id)
        assertEquals((780912345.25 + 978307200) * 1000, mac.value.updated_at_millis.toDouble())
    }

    @Test
    fun appleEndpointsTokensAndOutbox() {
        val (gateways, active, machine) = LegacyFormats.appleEndpoints(
            """[{"name":"Dieter Gateway","host":"gateway.getdieter.com","port":443,"secure":true},{"name":"LAN","host":"10.0.0.2","port":4242,"secure":false}]""",
            """{"name":"Studio","host":"gateway.getdieter.com","port":443,"secure":true,"daemonID":"d_1","online":true}""",
        )
        assertEquals(listOf(gateway), gateways.map { it.origin })
        assertEquals(gateway, active)
        assertEquals("d_1", machine)
        assertEquals(mapOf(gateway to "tok"), LegacyFormats.macTokens("""{"https:\/\/gateway.getdieter.com:443":"tok","nonsense":""}"""))

        val entries = LegacyFormats.macOutbox(
            """{"version":1,"revision":12,"entries":[
                {"commandID":"c1","clientID":"mac_1","endpointID":"https:\/\/gateway.getdieter.com:443#d_1","kind":"createCard","request":"$createBase64",
                 "optimisticID":"c_4e1d","attempts":1,"lastError":"unavailable","state":"retrying","nextAttemptAt":780912350.5,"createdAt":780912345.0},
                {"commandID":"c2","clientID":"mac_1","endpointID":"d_1","kind":"sendMessage","request":"$sendBase64","optimisticID":"msg_2","serverID":"msg_2",
                 "attempts":0,"state":"queued","optimisticPlacement":"queue","createdAt":780912400.0}]}""",
            activeOrigin = gateway,
        )
        assertEquals(listOf("d_1", "d_1"), entries.map { it.value.daemon_id })
        assertEquals(OutboxKind.OUTBOX_KIND_CREATE_CARD, entries[0].value.kind)
        assertEquals(OutboxState.OUTBOX_STATE_RETRYING, entries[0].value.state)
        assertEquals(create, CreateConversationRequest.ADAPTER.decode(entries[0].value.request))
        assertEquals("msg_2", entries[1].value.server_id)
        assertEquals((780912345L + 978307200L) * 1000, entries[0].value.created_at_millis)
        assertEquals(OutboxPlacement.OUTBOX_PLACEMENT_QUEUE, entries[1].value.placement)
        assertEquals(emptyList(), LegacyFormats.macOutbox("""{"version":2,"entries":[]}""", gateway), "a newer journal is not guessed at")
    }

    @Test
    fun appleSelectionsCreationAndNotifications() {
        val selections = LegacyFormats.macTerminalSelections(mapOf("$gateway#d_1||" to "t_1", "$gateway#d_1|p_1|c_1" to "t_2", "bad" to "t_3"))
        assertEquals(setOf("d_1||" to "t_1", "d_1|p_1|c_1" to "t_2"), selections.map { it.value }.toSet())
        val creation = LegacyFormats.macCreation("""{"project":"p_1","boards":{"p_1":"b_3"},"provider":"codex","model":"m","effort":"high","options":{"reasoning":"on"}}""", null)
        assertEquals("worktree", creation.workspace_mode, "a missing mode meant a worktree")
        assertEquals(mapOf("p_1" to "b_3"), creation.boards)
        assertEquals(mapOf("reasoning" to "on"), creation.provider_options)
        assertEquals(false, LegacyFormats.macNotifications(null).enabled, "notifications were off unless chosen on macOS")
    }
}
