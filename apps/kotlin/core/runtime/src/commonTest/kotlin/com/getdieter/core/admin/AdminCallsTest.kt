package com.getdieter.core.admin

import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.store.WorkspaceStore
import com.getdieter.core.testing.offlineSessions
import com.getdieter.core.testing.unreachableChoice
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlinx.coroutines.test.runTest
import okio.ByteString.Companion.encodeUtf8

/**
 * Routing and idempotent intents of administrative calls, and the checks every part makes before
 * any machine is called, on a client with no reachable machine.
 */
class AdminCallsTest {
    private val store = WorkspaceStore()
    private val calls = AdminCalls(offlineSessions(), store, unreachableChoice(store))
    private val admin = Administration(offlineSessions(), store, unreachableChoice(store))

    private suspend fun attempt(calls: AdminCalls, intent: String, succeed: Boolean): String {
        var used = ""
        runCatching {
            calls.idempotent("board", intent.encodeUtf8()) { id ->
                used = id
                check(succeed) { "unreachable" }
            }
        }
        return used
    }

    @Test
    fun aRetriedIntentReusesItsOperationIdUntilItSucceeds() = runTest {
        val first = attempt(calls, "retire:b1:true", succeed = false)
        assertEquals(1, calls.pendingIntents)
        assertEquals(first, attempt(calls, "retire:b1:true", succeed = false), "a retry")
        assertNotEquals(first, attempt(calls, "retire:b1:false", succeed = false), "another intent")
        assertEquals(2, calls.pendingIntents)

        assertEquals(first, attempt(calls, "retire:b1:true", succeed = true))
        assertEquals(1, calls.pendingIntents, "a succeeded intent is forgotten")
        assertNotEquals(
            first,
            attempt(calls, "retire:b1:true", succeed = false),
            "the same intent later is a new operation",
        )
    }

    @Test
    fun onlyTheNewestIntentsKeepTheirOperationIds() = runTest {
        val oldest = attempt(calls, "intent-0", succeed = false)
        val newest = (1..AdminCalls.MAX_INTENTS).map { attempt(calls, "intent-$it", false) }.last()
        assertEquals(AdminCalls.MAX_INTENTS, calls.pendingIntents)
        assertNotEquals(oldest, attempt(calls, "intent-0", succeed = false), "evicted")
        assertEquals(newest, attempt(calls, "intent-${AdminCalls.MAX_INTENTS}", false))
    }

    @Test
    fun callsWithoutAReachableMachineFailTransiently() {
        fun failure(route: AdminRoute) = assertFailsWith<CoreException> { calls.daemonFor(route) }
        assertEquals("d1", calls.daemonFor(AdminRoute.Target("d1")))
        for ((route, message) in
            listOf(
                AdminRoute.ForProject("p") to "No machine with this project is reachable.",
                AdminRoute.Observer("board/b.retired", "p") to
                    "No machine with this project is reachable.",
                AdminRoute.Owner("c", "p") to "The checkout’s machine is unavailable",
                AdminRoute.Anywhere to "No machine is reachable.",
            )) {
            val error = failure(route)
            assertEquals(message, error.message, "$route")
            assertEquals(FailureKind.TRANSIENT, error.kind, "$route")
        }
        val unknown = assertFailsWith<CoreException> { calls.projectOf("b_gone") }
        assertEquals("The board is no longer available.", unknown.message)
        assertEquals(FailureKind.PERMANENT, unknown.kind)
    }

    @Test
    fun formsAreCheckedBeforeAnyMachineIsCalled() = runTest {
        suspend fun problem(block: suspend () -> Any?) =
            assertFailsWith<CoreException> { block() }
                .also {
                    assertEquals(FailureKind.PERMANENT, it.kind)
                }
                .message
        assertEquals("board name is required", problem { admin.boards.create("p", " ") })
        assertEquals("board name is required", problem { admin.boards.rename("b", "") })
        assertEquals(
            "Done archive policy must be never, immediately, after_1_day, after_7_days, after_30_days, or after_90_days",
            problem { admin.boards.setArchivePolicy("b", "weekly") },
        )
        assertEquals(
            "remote publish mode must be manual, pull_request, or push_base",
            problem { admin.boards.setGitSettings("b", "origin", "merge") },
        )
        assertEquals(
            "at most 64 project hostnames are allowed",
            problem { admin.boards.setHostnames("b", List(65) { "h$it" }) },
        )
        assertEquals("label name is required", problem { admin.boards.createLabel("b", " ") })
        assertEquals(
            "label color must be a hex color such as #6558df",
            problem { admin.boards.updateLabel("b", "l", "Bug", "red", "") },
        )
        assertEquals(
            "board skill template: template is required",
            problem {
                admin.prompts.updateSettings(
                    "d1",
                    "{{project.instructions_block}} {{labels.instructions_block}}",
                    " ",
                    "chat",
                )
            },
        )
        assertEquals(
            "template must contain {{project.instructions_block}} exactly once",
            problem { admin.prompts.setProjectPrompt("p", "Hello") },
        )
        assertEquals(
            "The conversation is no longer available.",
            problem { admin.conversations.workspace("c_gone") },
        )
        assertEquals(
            "The project is no longer available.",
            problem { admin.projects.consolidate("p", "p") },
        )
    }
}
