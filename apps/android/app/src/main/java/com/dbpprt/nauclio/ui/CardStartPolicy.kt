package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.Board
import com.dbpprt.nauclio.v1.Card

internal fun Card.canStartFromTodo(hasDraftAttachments: Boolean = false): Boolean =
    scope == "board" &&
        lane.equals("todo", ignoreCase = true) &&
        (initialPrompt.isNotBlank() || hasDraftAttachments) &&
        initialPromptSentAt.isBlank()

internal fun Board.runningLaneId(): String? =
    lanesList.firstOrNull { it.id.equals("running", ignoreCase = true) }?.id
        ?: lanesList.firstOrNull { it.name.equals("running", ignoreCase = true) }?.id

internal fun Card.startLane(board: Board?): String? =
    if (canStartFromTodo()) board?.runningLaneId() else null
