package com.getdieter.core.domains

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Execution
import com.getdieter.api.v1.ExecutionEvent
import com.getdieter.api.v1.ExecutionStream
import com.getdieter.api.v1.Project
import com.getdieter.core.executions.ProcessTarget
import com.getdieter.core.executions.Processes
import com.getdieter.core.search.SearchDocument
import com.getdieter.core.search.TaskSearchIndex
import com.getdieter.core.testing.offlineSessions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import okio.ByteString.Companion.encodeUtf8

class DomainRulesTest {
    @Test
    fun processOutputIsBoundedAtCharacterBoundaries() {
        val (small, trimmedSmall) = Processes.append("ab".encodeUtf8(), "c".encodeUtf8())
        assertEquals("abc", small.utf8())
        assertFalse(trimmedSmall)
        val big = "é".repeat(Processes.MAX_STREAM_BYTES / 2 + 10).encodeUtf8()
        val (kept, trimmed) = Processes.append("x".encodeUtf8(), big)
        assertTrue(trimmed)
        assertTrue(kept.size <= Processes.MAX_STREAM_BYTES)
        assertTrue(kept.utf8().all { it == 'é' }, "the kept output starts on a character")
    }

    @Test
    fun processEventsApplyInSequenceAndResetReplays() {
        val processes = Processes(offlineSessions(), CoroutineScope(Dispatchers.Unconfined))
        val target = ProcessTarget("d", "p", "c")
        val execution =
            Execution(id = "e", project_id = "p", card_id = "c", status = "running", sequence = 1)
        processes.receive(
            ExecutionEvent(
                execution = execution,
                sequence = 1,
                stream = ExecutionStream.EXECUTION_STREAM_STDOUT,
                data_ = "one ".encodeUtf8(),
                reset = true,
            ),
            target,
        )
        processes.receive(
            ExecutionEvent(
                execution = execution.copy(sequence = 2),
                sequence = 2,
                stream = ExecutionStream.EXECUTION_STREAM_STDERR,
                data_ = "oops".encodeUtf8(),
            ),
            target,
        )
        processes.receive(
            ExecutionEvent(
                execution = execution,
                sequence = 2,
                stream = ExecutionStream.EXECUTION_STREAM_STDOUT,
                data_ = "dup".encodeUtf8(),
            ),
            target,
        )
        processes.receive(
            ExecutionEvent(
                execution = execution.copy(sequence = 3),
                sequence = 3,
                stream = ExecutionStream.EXECUTION_STREAM_PTY,
                data_ = "two".encodeUtf8(),
            ),
            target,
        )
        processes.receive(
            ExecutionEvent(
                execution = execution.copy(card_id = "other"),
                sequence = 4,
                stream = ExecutionStream.EXECUTION_STREAM_STDOUT,
                data_ = "foreign".encodeUtf8(),
            ),
            target,
        )
        assertEquals("one two", processes.view.value.stdout.utf8())
        assertEquals("oops", processes.view.value.stderr.utf8())
    }

    @Test
    fun searchMatchesPrefixesOfEveryTermAndRanksTitles() {
        val index =
            TaskSearchIndex(
                listOf(
                    SearchDocument(
                        "1",
                        "Fix login",
                        "Users cannot sign in",
                        "Dieter · Main",
                        "2026-01-01",
                    ),
                    SearchDocument("2", "Login page redesign", "", "", "2026-01-03"),
                    SearchDocument("3", "Café menu", "Résumé upload", "", "2026-01-02"),
                    SearchDocument("4", "Archived login", "", "", "2026-01-05", archived = true),
                    SearchDocument("1", "Old title", "", "", "2025-01-01"),
                )
            )
        assertEquals(
            listOf("2", "1"),
            index.search("login").map { it.id },
            "a leading title match ranks first",
        )
        assertEquals(listOf("1"), index.search("fix log").map { it.id })
        assertEquals(listOf("3"), index.search("resume cafe").map { it.id }, "accents are ignored")
        assertEquals(
            listOf("1"),
            index.search("dieter main").map { it.id },
            "location is searchable",
        )
        assertTrue(index.search("login missing").isEmpty())
        assertTrue(index.search("   ").isEmpty())
        assertEquals(
            "Fix login",
            index.search("fix").single().title,
            "the newer copy of a document wins",
        )

        val cards =
            listOf(
                Card(id = "c", scope = "chat", project_id = "p"),
                Card(id = "f", scope = "chat", project_id = "p", board_id = "b"),
                Card(id = "t", scope = "board", project_id = "p", board_id = "b"),
            )
        val documents =
            TaskSearchIndex.documents(
                cards,
                listOf(Project(id = "p", name = "Dieter")),
                listOf(Board(id = "b", name = "Main")),
            )
        assertEquals(
            listOf("c"),
            documents.filter { it.chat }.map { it.id },
            "a chat filed on a board is found as a card",
        )
        assertEquals("Dieter · Main", documents.single { it.id == "f" }.location)
    }
}
