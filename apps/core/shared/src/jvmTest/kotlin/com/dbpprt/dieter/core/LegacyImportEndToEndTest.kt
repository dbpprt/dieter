package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.composition.DraftKey
import com.dbpprt.dieter.core.legacy.LegacyFormats
import com.dbpprt.dieter.core.legacy.LegacyState
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** A macOS install's legacy state becomes the core's on first launch, and its queued card is delivered once. */
class LegacyImportEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun aLegacyInstallKeepsItsSessionQueuedCardAndDraft() = e2e {
        val fixture = fixture()
        val legacyClient = "mac_2f9e6a4c-1d3b-4e8f-a7c2-9b5d0e3f6a18"
        val runtime = runtime(fixture, token = null, start = false) { it.copy(legacyClientId = { legacyClient }) }
        assertEquals(legacyClient, runtime.clientId, "the install keeps its sync identity")
        val origin = gatewayOf(fixture).origin
        val request = CreateConversationRequest(
            project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "Queued before the update", prompt = "p",
            defer_start = true, workspace_mode = "project", client_id = legacyClient, command_id = "5b0c2d1e-8f3a-4c7b-9e21-0a6d4f1b7c33",
        )
        // The macOS journal (pending-commands.json); dates are seconds since 2001.
        val outbox = """{"version":1,"revision":3,"entries":[{"commandID":"${request.command_id}","clientID":"$legacyClient","endpointID":"$origin#${fixture.daemonId}",
            "kind":"createCard","request":"${CreateConversationRequest.ADAPTER.encodeByteString(request).base64()}","optimisticID":"${OutboxPolicy.localConversationId(request.command_id)}",
            "attempts":1,"lastError":"offline","state":"retrying","createdAt":811693200.0}]}"""
        val entries = LegacyFormats.macOutbox(outbox, origin)
        val local = entries.single().value.optimistic_id
        val drafts = """{"version":1,"drafts":[{"target":{"endpointID":"$origin#${fixture.daemonId}","conversationID":"$local"},"text":"a follow-up","updatedAt":811693300.0}]}"""
        val state = LegacyState(
            gateways = listOf(gatewayOf(fixture)), activeOrigin = origin, preferredMachines = mapOf(origin to fixture.daemonId),
            tokens = mapOf(origin to fixture.token), outbox = entries, drafts = LegacyFormats.macDrafts(drafts),
        )

        assertTrue(runtime.needsLegacyImport)
        val report = runtime.importLegacy(state)
        assertEquals(1, report.tokens)
        assertEquals(1, report.outboxEntries)
        assertEquals(1, report.drafts)
        assertTrue(runtime.importLegacy(state).skipped, "the import runs once")

        runtime.start()
        runtime.setActive(true)
        runtime.awaitConnected()
        val card = runtime.workspace.state.await(30.seconds, describe = { "delivered: ${runtime.outbox.view.value.entries}" }) { view ->
            view.allItems.any { it.title == "Queued before the update" && OutboxPolicy.isServerBacked(it.id) }
        }.allItems.single { it.title == "Queued before the update" }
        assertEquals(OutboxPolicy.expectedConversationId(legacyClient, request.command_id), card.id, "the daemon sees the legacy command exactly once")
        runtime.outbox.view.await(30.seconds) { it.entries.isEmpty() }
        assertEquals(1, runtime.workspace.state.value.allItems.count { it.title == "Queued before the update" })
        // The draft written against the local ID follows the card to its server ID.
        runtime.drafts.state.await(describe = { "draft retargeted: ${runtime.drafts.state.value}" }) { it[DraftKey(fixture.daemonId, card.id)]?.text == "a follow-up" }
    }
}
