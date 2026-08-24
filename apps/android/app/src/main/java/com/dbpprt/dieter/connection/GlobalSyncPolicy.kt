package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.GlobalDelta

internal fun GlobalDelta.changesProjection(): Boolean =
    projectsCount > 0 || removedProjectIdsCount > 0 ||
        boardsCount > 0 || removedBoardIdsCount > 0 ||
        cardsCount > 0 || removedCardIdsCount > 0 ||
        chatsCount > 0 || removedChatIdsCount > 0 ||
        schedulesCount > 0 || removedScheduleIdsCount > 0 ||
        scheduleRunsCount > 0 || removedScheduleRunIdsCount > 0 ||
        hasSettings() ||
        conversationsCount > 0 || removedConversationIdsCount > 0
