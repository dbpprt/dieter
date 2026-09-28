package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.BoardRetirementVersion
import com.dbpprt.dieter.v1.Card
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class BoardLifecycleTest {
    @Test fun sharedLifecycleFixture() {
        val root = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .first { File(it, "tests/fixtures/board-lifecycle.tsv").exists() }
        File(root, "tests/fixtures/board-lifecycle.tsv").readLines().filterNot { it.startsWith("#") || it.isBlank() }.forEach { line ->
            val columns = line.split('\t')
            val boards = columns[1].split(';').map { observation ->
                val board = Board.newBuilder().setId("b_fixture").setProjectId("project")
                if (observation != "-") {
                    val pair = observation.split('=')
                    val version = BoardRetirementVersion.newBuilder().setRank(observation).setRetired(pair[1] == "true")
                    pair[0].split(',').forEach {
                        val clock = it.split(':'); version.putClock(clock[0], clock[1].toLong())
                    }
                    board.addRetirementVersions(version).setRetired(version.retired).setRetirementRevision(observation)
                }
                board.build()
            }
            val cards = if (columns[2] == "true") listOf(Card.newBuilder().setId("card").setBoardId("b_fixture").build()) else emptyList()
            val result = sharedBoardDirectory(boards, cards)
            val board = (result.active + result.retired).single()
            assertEquals(columns[0], columns[3].toBoolean(), board.retired)
            assertEquals(columns[0], columns[4].toBoolean(), board.retirementBlocked)
            // A delayed pre-retirement observation cannot remove cached causal evidence.
            val replay = sharedBoardDirectory(listOf(board, boards.first()), cards)
            assertEquals(result, replay)
        }
    }
}
