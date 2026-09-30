package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class CardSwipeActionsTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun swipeDrawerExposesWorkingEditMoveAndArchiveActions() {
        val revealed = mutableStateOf(false)
        val invokedActions = mutableListOf<String>()
        val status = mutableStateOf("Ready")
        val card = Card(id = "card-1", board_id = "board-1", lane = "running", scope = "board", title = "Check the Android swipe actions", initial_prompt = "Exercise every action without mutating server data.", created_at = "2026-09-09T10:00:00Z")
        val board = Board(id = "board-1", lanes = listOf(Lane(id = "todo", name = "Todo"), Lane(id = "running", name = "Running"), Lane(id = "review", name = "Review")))

        compose.setContent {
            DieterTheme(darkTheme = true) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.safeDrawingPadding().padding(16.dp)) {
                        SwipeableWorkCard(
                            card = card,
                            board = board,
                            selected = false,
                            pending = false,
                            operation = null,
                            operationError = null,
                            activityNow = java.time.Instant.parse("2026-09-09T10:00:00Z"),
                            revealed = revealed.value,
                            onReveal = { revealed.value = true },
                            onCloseActions = { revealed.value = false },
                            onMove = { recordAction("Move", invokedActions, status, revealed) },
                            onEdit = { recordAction("Edit", invokedActions, status, revealed) },
                            onArchive = { recordAction("Archive", invokedActions, status, revealed) },
                            onStart = {},
                            labelDragState = BoardLabelDragState(),
                            onClick = {},
                        )
                        androidx.compose.material3.Text(
                            status.value,
                            modifier = Modifier.padding(top = 160.dp),
                        )
                    }
                }
            }
        }

        compose.onNodeWithTag("edit-card-card-1").assertIsNotEnabled()
        compose.onNodeWithTag("move-card-card-1").assertIsNotEnabled()
        compose.onNodeWithTag("archive-card-card-1").assertIsNotEnabled()

        invokeThroughDrawer("move-card-card-1", "Move worked")
        invokeThroughDrawer("edit-card-card-1", "Edit worked")
        invokeThroughDrawer("archive-card-card-1", "Archive worked")

        compose.runOnIdle {
            assertEquals(listOf("Move", "Edit", "Archive"), invokedActions)
        }
    }

    private fun invokeThroughDrawer(actionTag: String, expectedStatus: String) {
        compose.onNodeWithTag("swipe-card-card-1").performTouchInput {
            swipeLeft(durationMillis = 500)
        }
        compose.waitForIdle()
        compose.onNodeWithTag(actionTag).assertIsDisplayed().assertIsEnabled().performClick()
        compose.onNodeWithText(expectedStatus).assertIsDisplayed()
    }
}

private fun recordAction(
    action: String,
    invokedActions: MutableList<String>,
    status: androidx.compose.runtime.MutableState<String>,
    revealed: androidx.compose.runtime.MutableState<Boolean>,
) {
    invokedActions += action
    status.value = "$action worked"
    revealed.value = false
}
